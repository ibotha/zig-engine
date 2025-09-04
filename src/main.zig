const std = @import("std");
const c = @import("c.zig");
const Vulkan = @import("vulkan.zig").Vulkan;
const Swapchain = @import("swapchain.zig").Swapchain;
const Allocator = std.mem.Allocator;
const vk = @import("vulkan");
const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

const MIN_IMAGE_COUNT = 2;

fn check_vk_result(err: c.c.VkResult) callconv(std.builtin.CallingConvention.c) void {
    if (err == 0) return;
    std.debug.print("[vulkan] Error: VkResult = {d}\n", .{err});
    if (err < 0) std.process.exit(1);
}

const Vertex = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};
fn glfw_error_callback(err: c_int, description: [*c]const u8) callconv(std.builtin.CallingConvention.c) void {
    std.debug.print("GLFW Error {d}: {s}\n", .{ err, description });
}

fn key_callback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, pressed: c_int, mods: c_int) callconv(std.builtin.CallingConvention.c) void {
    _ = scancode;
    if (key == c.c.GLFW_KEY_R and pressed == 1 and (mods & c.c.GLFW_MOD_SHIFT) != 0) {}
    if (key == c.c.GLFW_KEY_ESCAPE) {
        c.c.glfwSetWindowShouldClose(window, c.GLFW_TRUE);
    }
}

fn loader(name: [*c]const u8, instance: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*const fn () callconv(std.builtin.CallingConvention.c) void {
    return c.glfwGetInstanceProcAddress(@enumFromInt(@intFromPtr(instance)), name);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) {
        @panic("Leak detected in engine");
    };
    const allocator = gpa.allocator();

    // ========== Init GLFW ==============
    _ = c.glfwSetErrorCallback(glfw_error_callback);
    if (c.glfwInit() == 0) return error.glfwInitFailure;
    defer c.glfwTerminate();

    if (c.glfwVulkanSupported() == 0) return error.VulkanNotSupported;

    var extent = vk.Extent2D{ .width = 800, .height = 600 };
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        "Engine",
        null,
        null,
    );
    if (window == null) return error.WindowNotCreated;
    defer c.glfwDestroyWindow(window);

    _ = c.glfwSetKeyCallback(window, key_callback);

    // ========= Vulkan ============
    extent.width, extent.height = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);
        break :blk .{ @intCast(w), @intCast(h) };
    };
    var v = try Vulkan.init(allocator, "test", window.?);
    defer v.deinit();

    std.log.debug("Using device: {s}", .{v.deviceName()});

    var swapchain = try Swapchain.init(&v, allocator, extent);
    defer swapchain.deinit();

    const pipeline_layout = try v.dev.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer v.dev.destroyPipelineLayout(pipeline_layout, null);

    const render_pass = try createRenderPass(&v, swapchain);
    defer v.dev.destroyRenderPass(render_pass, null);

    const pipeline = try createPipeline(&v, pipeline_layout, render_pass);
    defer v.dev.destroyPipeline(pipeline, null);

    var framebuffers = try createFramebuffers(&v, allocator, render_pass, swapchain);
    defer destroyFramebuffers(&v, allocator, framebuffers);

    const pool = try v.dev.createCommandPool(&.{
        .queue_family_index = v.graphics_queue.family,
    }, null);
    defer v.dev.destroyCommandPool(pool, null);

    const buffer = try v.dev.createBuffer(&.{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer v.dev.destroyBuffer(buffer, null);
    const mem_reqs = v.dev.getBufferMemoryRequirements(buffer);
    const memory = try v.allocate(mem_reqs, .{ .device_local_bit = true });
    defer v.dev.freeMemory(memory, null);
    try v.dev.bindBufferMemory(buffer, memory, 0);

    try uploadVertices(&v, pool, buffer, &[_]f32{ 1.0, 1.0, 1.0 }, 0, 0);

    var cmdbufs = try createCommandBuffers(
        &v,
        pool,
        allocator,
        buffer,
        swapchain.extent,
        render_pass,
        pipeline,
        framebuffers,
    );
    defer destroyCommandBuffers(&v, pool, allocator, cmdbufs);

    // ========= IMGUI ===============
    if (!c.c.cImGui_ImplVulkan_LoadFunctions(@as(u32, @bitCast(vk.API_VERSION_1_2)), loader)) return error.ImGuiVulkanLoadFailure;

    // Setup Dear ImGui context
    if (c.c.ImGui_CreateContext(null) == null) return error.ImGuiCreateContextFailure;
    defer c.c.ImGui_DestroyContext(null);
    const io = c.c.ImGui_GetIO(); // (void)io;
    io.*.ConfigFlags |= c.c.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls
    io.*.ConfigFlags |= c.c.ImGuiConfigFlags_NavEnableGamepad; // Enable Gamepad Controls
    io.*.ConfigFlags |= c.c.ImGuiConfigFlags_DockingEnable;

    // Setup Dear ImGui style
    c.c.ImGui_StyleColorsDark(null);
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        },
    };
    var pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 1,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @ptrCast(&pool_sizes),
    };
    const descriptorPool = try v.dev.createDescriptorPool(&pool_info, null);
    defer v.dev.destroyDescriptorPool(descriptorPool, null);

    // Setup Platform/Renderer backends
    if (!c.c.cImGui_ImplGlfw_InitForVulkan(window, true)) return error.ImGuiGlfwInitForVulkanFailure;
    defer c.c.cImGui_ImplGlfw_Shutdown();
    var init_info = c.c.ImGui_ImplVulkan_InitInfo{};
    init_info.Instance = @ptrFromInt(@intFromEnum(v.instance.handle));
    init_info.PhysicalDevice = @ptrFromInt(@intFromEnum(v.pdev));
    init_info.Device = @ptrFromInt(@intFromEnum(v.dev.handle));
    init_info.Queue = @ptrFromInt(@intFromEnum(v.graphics_queue.handle));
    init_info.RenderPass = @ptrFromInt(@intFromEnum(render_pass));
    init_info.DescriptorPool = @ptrFromInt(@intFromEnum(descriptorPool));
    init_info.MinImageCount = MIN_IMAGE_COUNT;
    init_info.ImageCount = @truncate(swapchain.swap_images.len);
    init_info.MSAASamples = c.c.VK_SAMPLE_COUNT_1_BIT;
    init_info.CheckVkResultFn = check_vk_result;
    if (!c.c.cImGui_ImplVulkan_Init(&init_info)) return error.ImGuiVulkanInitFailure;
    defer c.c.cImGui_ImplVulkan_Shutdown();

    // Our state
    var x: f32 = 0;
    var y: f32 = 0;
    var counter: i32 = 1;
    const clear_color: c.c.ImVec4 = .{ .x = 0.45, .y = 0.55, .z = 0.6, .w = 1.0 };
    const clear_color_slice = try allocator.alloc(f32, 3);
    defer allocator.free(clear_color_slice);
    clear_color_slice[0] = clear_color.x;
    clear_color_slice[1] = clear_color.y;
    clear_color_slice[2] = clear_color.z;

    // ========= Run loop

    var invalid_frame_buffers = [_]u1{0} ** 32;
    var state: Swapchain.PresentState = .optimal;
    while (c.glfwWindowShouldClose(window) == 0) {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);

        // Don't present or resize swapchain while the window is minimized

        const cmdbuf = cmdbufs[swapchain.image_index];

        if (state == .suboptimal or extent.width != @as(u32, @intCast(w)) or extent.height != @as(u32, @intCast(h))) {
            for (0..invalid_frame_buffers.len) |i| {
                invalid_frame_buffers[i] = 0;
            }
            extent.width = @intCast(w);
            extent.height = @intCast(h);
            try swapchain.recreate(extent);

            destroyFramebuffers(&v, allocator, framebuffers);
            framebuffers = try createFramebuffers(&v, allocator, render_pass, swapchain);

            destroyCommandBuffers(&v, pool, allocator, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &v,
                pool,
                allocator,
                buffer,
                swapchain.extent,
                render_pass,
                pipeline,
                framebuffers,
            );
        }

        const cmd_buffer = &cmdbufs[swapchain.image_index];
        const framebuffer = &framebuffers[swapchain.image_index];
        try uploadVertices(&v, pool, buffer, clear_color_slice, x, y);

        try start_frame(&v, pool, swapchain.currentSwapImage().frame_fence, cmd_buffer, extent, render_pass, pipeline, framebuffer);
        {
            const offset = [_]vk.DeviceSize{0};
            v.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&buffer), &offset);
            v.dev.cmdDraw(cmdbuf, vertices.len, 1, 0, 0);

            c.c.cImGui_ImplVulkan_NewFrame();
            c.c.cImGui_ImplGlfw_NewFrame();
            c.c.ImGui_NewFrame();
            const winclass = c.c.ImGuiWindowClass{
                .ClassId = 0,
                .ViewportFlagsOverrideClear = 1,
                .DockingAllowUnclassed = true,
            };

            c.c.ImGui_PushStyleColorImVec4(c.c.ImGuiCol_DockingEmptyBg, c.c.ImVec4{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 0.0 });
            c.c.ImGui_PushStyleColorImVec4(c.c.ImGuiCol_WindowBg, c.c.ImVec4{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 0.0 });
            _ = c.c.ImGui_DockSpaceOverViewportEx(0, null, 0, &winclass);
            c.c.ImGui_PopStyleColor();
            c.c.ImGui_PopStyleColor();

            defer {
                c.c.ImGui_Render();
                const draw_data = c.c.ImGui_GetDrawData();
                const is_minimized = (draw_data.*.DisplaySize.x <= 0.0 or draw_data.*.DisplaySize.y <= 0.0);
                if (!is_minimized) {
                    c.c.cImGui_ImplVulkan_RenderDrawData(draw_data, @ptrFromInt(@intFromEnum(cmd_buffer.*)));
                    // wd.ClearValue.color.float32[0] = clear_color.x * clear_color.w;
                    // wd.ClearValue.color.float32[1] = clear_color.y * clear_color.w;
                    // wd.ClearValue.color.float32[2] = clear_color.z * clear_color.w;
                    // wd.ClearValue.color.float32[3] = clear_color.w;
                    // FrameRender(&v, &swapchain, wd, draw_data) catch |err| {
                    //     std.debug.print("WTF!!!!! {any}\n", .{err});
                    // };
                }
            }
            // 1. Show the big demo window (Most of the sample code is in ImGui::ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).

            {
                _ = c.c.ImGui_Begin("Hello, world!", null, 0);
                defer c.c.ImGui_End();

                c.c.ImGui_Text("Position");

                _ = c.c.ImGui_SliderFloat("x", &x, -0.5, 0.5);
                _ = c.c.ImGui_SliderFloat("y", &y, -0.5, 0.5);
                _ = c.c.ImGui_ColorEdit3("clear color", clear_color_slice.ptr, 0);

                if (c.c.ImGui_Button("Button")) counter += 1;
                c.c.ImGui_SameLine();
                c.c.ImGui_Text("counter = %d", counter);

                c.c.ImGui_Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / io.*.Framerate, io.*.Framerate);
            }
        }

        try end_frame(&v, cmd_buffer);
        state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };
        c.glfwPollEvents();
    }

    try swapchain.waitForAllFences();
    try v.dev.deviceWaitIdle();
}

fn uploadVertices(v: *const Vulkan, pool: vk.CommandPool, buffer: vk.Buffer, col: []const f32, x: f32, y: f32) !void {
    const staging_buffer = try v.dev.createBuffer(&.{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer v.dev.destroyBuffer(staging_buffer, null);
    const mem_reqs = v.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try v.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer v.dev.freeMemory(staging_memory, null);
    try v.dev.bindBufferMemory(staging_buffer, staging_memory, 0);

    {
        const data = try v.dev.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer v.dev.unmapMemory(staging_memory);

        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, vertices[0..]);
        for (gpu_vertices[0..vertices.len]) |*vert| {
            vert.color[0] = col[0];
            vert.color[1] = col[1];
            vert.color[2] = col[2];
            vert.pos[0] += x;
            vert.pos[1] += y;
        }
    }

    try copyBuffer(v, pool, buffer, staging_buffer, @sizeOf(@TypeOf(vertices)));
}

fn copyBuffer(v: *const Vulkan, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try v.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));
    defer v.dev.freeCommandBuffers(pool, 1, @ptrCast(&cmdbuf_handle));

    const cmdbuf = Vulkan.CommandBuffer.init(cmdbuf_handle, v.dev.wrapper);

    try cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    cmdbuf.copyBuffer(src, dst, 1, @ptrCast(&region));

    try cmdbuf.endCommandBuffer();

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    };
    try v.dev.queueSubmit(v.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try v.dev.queueWaitIdle(v.graphics_queue.handle);
}

fn start_frame(
    v: *const Vulkan,
    pool: vk.CommandPool,
    fence: vk.Fence,
    cmd_buffer: *vk.CommandBuffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffer: *vk.Framebuffer,
) !void {
    _ = try v.dev.waitForFences(1, @ptrCast(&fence), .true, std.math.maxInt(u64));
    v.dev.freeCommandBuffers(pool, 1, @ptrCast(cmd_buffer));
    try v.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(cmd_buffer));

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    try v.dev.beginCommandBuffer(cmd_buffer.*, &.{});

    v.dev.cmdSetViewport(cmd_buffer.*, 0, 1, @ptrCast(&viewport));
    v.dev.cmdSetScissor(cmd_buffer.*, 0, 1, @ptrCast(&scissor));

    // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
    const render_area = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    v.dev.cmdBeginRenderPass(cmd_buffer.*, &.{
        .render_pass = render_pass,
        .framebuffer = framebuffer.*,
        .render_area = render_area,
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&clear),
    }, .@"inline");

    v.dev.cmdBindPipeline(cmd_buffer.*, .graphics, pipeline);
}

fn end_frame(
    v: *const Vulkan,
    cmd_buffer: *vk.CommandBuffer,
) !void {
    v.dev.cmdEndRenderPass(cmd_buffer.*);
    try v.dev.endCommandBuffer(cmd_buffer.*);
}

fn createCommandBuffers(
    v: *const Vulkan,
    pool: vk.CommandPool,
    allocator: Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer allocator.free(cmdbufs);

    try v.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer v.dev.freeCommandBuffers(pool, @intCast(cmdbufs.len), cmdbufs.ptr);

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    for (cmdbufs, framebuffers) |cmdbuf, framebuffer| {
        try v.dev.beginCommandBuffer(cmdbuf, &.{});

        v.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
        v.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));

        // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        v.dev.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");

        v.dev.cmdBindPipeline(cmdbuf, .graphics, pipeline);
        const offset = [_]vk.DeviceSize{0};
        v.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&buffer), &offset);
        v.dev.cmdDraw(cmdbuf, vertices.len, 1, 0, 0);

        v.dev.cmdEndRenderPass(cmdbuf);
        try v.dev.endCommandBuffer(cmdbuf);
    }

    return cmdbufs;
}

fn destroyCommandBuffers(v: *const Vulkan, pool: vk.CommandPool, allocator: Allocator, cmdbufs: []vk.CommandBuffer) void {
    v.dev.freeCommandBuffers(pool, @truncate(cmdbufs.len), cmdbufs.ptr);
    allocator.free(cmdbufs);
}

fn createFramebuffers(v: *const Vulkan, allocator: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| v.dev.destroyFramebuffer(fb, null);

    for (framebuffers) |*fb| {
        fb.* = try v.dev.createFramebuffer(&.{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(v: *const Vulkan, allocator: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| v.dev.destroyFramebuffer(fb, null);
    allocator.free(framebuffers);
}

fn createRenderPass(v: *const Vulkan, swapchain: Swapchain) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };

    return try v.dev.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
}

fn createPipeline(
    v: *const Vulkan,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
) !vk.Pipeline {
    const vert = try v.dev.createShaderModule(&.{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(&vert_spv),
    }, null);
    defer v.dev.destroyShaderModule(vert, null);

    const frag = try v.dev.createShaderModule(&.{
        .code_size = frag_spv.len,
        .p_code = @ptrCast(&frag_spv),
    }, null);
    defer v.dev.destroyShaderModule(frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
    };

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
        .scissor_count = 1,
        .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try v.dev.createGraphicsPipelines(
        .null_handle,
        1,
        @ptrCast(&gpci),
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}

fn SetupVulkanWindow(
    v: *Vulkan,
    wd: *c.c.ImGui_ImplVulkanH_Window,
    s: *Swapchain,
    width: i32,
    height: i32,
) !void {
    const res = try v.instance.getPhysicalDeviceSurfaceSupportKHR(v.pdev, v.graphics_queue.family, v.surface);
    if (res != .true) return error.NoWSISupport;

    const sem_count: c_int = @intCast(s.swap_images.len + 1);
    const img_count: c_int = @intCast(s.swap_images.len);
    wd.* = .{
        .PresentMode = @intCast(@intFromEnum(s.present_mode)),
        .Surface = @ptrFromInt(@intFromEnum(v.surface)),
        .ClearEnable = true,
        .Swapchain = @ptrFromInt(@intFromEnum(s.handle)),
        .SurfaceFormat = @bitCast(s.surface_format),
        .Width = width,
        .Height = height,
        .SemaphoreCount = @intCast(sem_count),
        .FrameSemaphores = .{
            .Capacity = sem_count,
            .Data = @ptrCast(try v.allocator.alloc(c.c.ImGui_ImplVulkanH_FrameSemaphores, @intCast(sem_count))),
            .Size = sem_count,
        },
        .ImageCount = @intCast(img_count),
        .Frames = .{
            .Capacity = img_count,
            .Data = @ptrCast(try v.allocator.alloc(c.c.ImGui_ImplVulkanH_Frame, @intCast(img_count))),
            .Size = img_count,
        },
        .FrameIndex = 0,
        .SemaphoreIndex = 0,
        .UseDynamicRendering = false,
    };
    {
        var attachment = vk.AttachmentDescription{
            .format = s.surface_format.format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .dont_care,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };
        const color_attachment = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };
        const subpass = vk.SubpassDescription{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
        };
        const zero: u32 = 0;
        const dependency = vk.SubpassDependency{
            .src_subpass = ~zero,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true },
        };
        const info = vk.RenderPassCreateInfo{
            .attachment_count = 1,
            .p_attachments = @ptrCast(&attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 1,
            .p_dependencies = @ptrCast(&dependency),
        };
        wd.RenderPass = @ptrFromInt(@intFromEnum(try v.dev.createRenderPass(&info, null)));
    }
    for (0..wd.ImageCount) |i| {
        const fd = &wd.Frames.Data[i];
        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = v.graphics_queue.family,
        };
        const cmd_pool = try v.dev.createCommandPool(&pool_info, null);
        fd.CommandPool = @ptrFromInt(@intFromEnum(cmd_pool));
        const cba_info = vk.CommandBufferAllocateInfo{
            .command_pool = cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try v.dev.allocateCommandBuffers(&cba_info, @ptrCast(&fd.CommandBuffer));
        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };
        const fence = try v.dev.createFence(&fence_info, null);
        fd.Fence = @ptrFromInt(@intFromEnum(fence));
        fd.Backbuffer = @ptrFromInt(@intFromEnum(s.swap_images[i].image));
        fd.BackbufferView = @ptrFromInt(@intFromEnum(s.swap_images[i].view));
        const fb_info = vk.FramebufferCreateInfo{
            .render_pass = @enumFromInt(@intFromPtr(wd.RenderPass)),
            .height = @intCast(height),
            .width = @intCast(width),
            .flags = .{},
            .attachment_count = 1,
            .p_attachments = @ptrCast(&s.swap_images[i].view),
            .layers = 1,
        };
        const framebuffer = try v.dev.createFramebuffer(&fb_info, null);
        fd.Framebuffer = @ptrFromInt(@intFromEnum(framebuffer));
        // = .{
        //     .BackbufferView = @ptrFromInt(@intFromEnum(s.swap_images[i].view)),
        //     .Framebuffer = @ptrFromInt(@intFromEnum(framebuffers[i])),
        //     .CommandBuffer = @ptrFromInt(@intFromEnum(cmdbufs[i])),
        //     .CommandPool = @ptrFromInt(@intFromEnum(pool)),
        //     .Fence = @ptrFromInt(@intFromEnum(s.swap_images[i].frame_fence)),
        // };
    }
    for (0..wd.SemaphoreCount) |i| {
        wd.FrameSemaphores.Data[i].ImageAcquiredSemaphore = @ptrFromInt(@intFromEnum(try v.dev.createSemaphore(&.{}, null)));
        wd.FrameSemaphores.Data[i].RenderCompleteSemaphore = @ptrFromInt(@intFromEnum(try v.dev.createSemaphore(&.{}, null)));
    }
}

fn CleanupVulkanWindow(
    v: *Vulkan,
    wd: *c.c.ImGui_ImplVulkanH_Window,
) void {
    for (0..wd.ImageCount) |i| {
        v.dev.destroyCommandPool(@enumFromInt(@intFromPtr(wd.Frames.Data[i].CommandPool)), null);
        v.dev.destroyFence(@enumFromInt(@intFromPtr(wd.Frames.Data[i].Fence)), null);
    }
    for (0..wd.SemaphoreCount) |i| {
        v.dev.destroySemaphore(@enumFromInt(@intFromPtr(wd.FrameSemaphores.Data[i].ImageAcquiredSemaphore)), null);
        v.dev.destroySemaphore(@enumFromInt(@intFromPtr(wd.FrameSemaphores.Data[i].RenderCompleteSemaphore)), null);
    }
    v.dev.destroyRenderPass(@enumFromInt(@intFromPtr(wd.RenderPass)), null);
    v.allocator.free(wd.Frames.Data[0..wd.ImageCount]);
    v.allocator.free(wd.FrameSemaphores.Data[0..wd.SemaphoreCount]);
}

fn FrameRender(
    v: *Vulkan,
    s: *Swapchain,
    wd: *c.c.ImGui_ImplVulkanH_Window,
    draw_data: *c.c.ImDrawData,
) !void {
    const fd = &wd.Frames.Data[s.image_index];

    _ = try v.dev.waitForFences(1, @ptrCast(&fd.Fence), .true, std.math.maxInt(u64));
    {
        try v.dev.resetFences(1, @ptrCast(&fd.Fence));
        try v.dev.resetCommandPool(@enumFromInt(@intFromPtr(fd.CommandPool)), .{});
        var info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };
        try v.dev.beginCommandBuffer(@enumFromInt(@intFromPtr(fd.CommandBuffer)), &info);
    }
    {
        var info = vk.RenderPassBeginInfo{
            .render_pass = @enumFromInt(@intFromPtr(wd.RenderPass)),
            .framebuffer = @enumFromInt(@intFromPtr(fd.Framebuffer)),
            .render_area = .{
                .extent = .{
                    .width = @intCast(wd.Width),
                    .height = @intCast(wd.Height),
                },
                .offset = .{
                    .x = 0,
                    .y = 0,
                },
            },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&wd.ClearValue),
        };
        v.dev.cmdBeginRenderPass(@enumFromInt(@intFromPtr(fd.CommandBuffer)), &info, .@"inline");
    }

    // Record dear imgui primitives into command buffer
    c.c.cImGui_ImplVulkan_RenderDrawData(draw_data, fd.CommandBuffer);

    // Submit command buffer
    v.dev.cmdEndRenderPass(@enumFromInt(@intFromPtr(fd.CommandBuffer)));

    try v.dev.endCommandBuffer(@enumFromInt(@intFromPtr(fd.CommandBuffer)));
}
