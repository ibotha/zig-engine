const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig");
const Platform = @import("platform").Platform;

const Allocator = std.mem.Allocator;

const APP_NAME = "WorkingAppTitle";

const required_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
const required_instance_extensions = [_][*:0]const u8{ vk.extensions.ext_debug_utils.name, vk.extensions.khr_surface.name, vk.extensions.khr_wayland_surface.name };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) {
        @panic("Leak detected in engine");
    };
    const allocator = gpa.allocator();

    // ========== Init GLFW ==============
    _ = c.glfwSetErrorCallback(glfw_error_callback);
    if (c.glfwInit() == 0) return error.glfwInitFailure;

    var extent = vk.Extent2D{ .width = 500, .height = 600 };
    const platform_data = Platform.init(allocator, .{
        .name = "TestBed",
        .size_hint = @bitCast(extent),
    }) catch |err| {
        std.log.err("Could not init platform! {any}", .{err});
        std.process.exit(1);
    };
    defer platform_data.deinit(allocator);
    // extent.height = platform_data.window.configured_height;
    // extent.width = platform_data.window.configured_width;
    // defer c.glfwTerminate();

    // if (c.glfwVulkanSupported() == 0) return error.VulkanNotSupported;

    // c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    // c.glfwWindowHint(c.c.GLFW_RESIZABLE, c.GLFW_TRUE);
    // const window = c.glfwCreateWindow(
    //     @intCast(extent.width),
    //     @intCast(extent.height),
    //     APP_NAME,
    //     null,
    //     null,
    // );
    // if (window == null) return error.WindowNotCreated;
    // defer c.glfwDestroyWindow(window);

    // _ = c.glfwSetKeyCallback(window, key_callback);

    // ============= Vulkan ==============

    // =============== ImGui ====================

    if (!c.c.cImGui_ImplVulkan_LoadFunctions(@as(u32, @bitCast(vk.API_VERSION_1_2)), loader)) return error.ImGuiVulkanLoadFailure;

    // Setup Dear ImGui context
    if (c.c.ImGui_CreateContext(null) == null) return error.ImGuiCreateContextFailure;
    defer c.c.ImGui_DestroyContext(null);
    const io = c.c.ImGui_GetIO(); // (void)io;
    io.*.ConfigFlags |= c.c.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls
    io.*.ConfigFlags |= c.c.ImGuiConfigFlags_NavEnableGamepad; // Enable Gamepad Controls
    io.*.ConfigFlags |= c.c.ImGuiConfigFlags_DockingEnable;
    io.*.DisplaySize = .{ .x = @floatFromInt(extent.width), .y = @floatFromInt(extent.height) };

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
    const descriptorPool = try dev.createDescriptorPool(&pool_info, &vk_allocator.callbacks);
    defer dev.destroyDescriptorPool(descriptorPool, &vk_allocator.callbacks);

    // Setup Platform/Renderer backends
    // if (!c.c.cImGui_ImplVulkan_Init(window, true)) return error.ImGuiGlfwInitForVulkanFailure;
    // defer c.c.cImGui_ImplGlfw_Shutdown();
    var init_info = c.c.ImGui_ImplVulkan_InitInfo{};
    init_info.Instance = @ptrFromInt(@intFromEnum(instance.handle));
    init_info.PhysicalDevice = @ptrFromInt(@intFromEnum(pdev));
    init_info.Device = @ptrFromInt(@intFromEnum(dev.handle));
    init_info.Queue = @ptrFromInt(@intFromEnum(graphics_queue.handle));
    init_info.RenderPass = null;
    init_info.DescriptorPool = @ptrFromInt(@intFromEnum(descriptorPool));
    init_info.MinImageCount = 2;
    init_info.ImageCount = @truncate(swap_images.len);
    init_info.MSAASamples = c.c.VK_SAMPLE_COUNT_1_BIT;
    init_info.CheckVkResultFn = check_vk_result;
    init_info.UseDynamicRendering = true;
    init_info.Allocator = @ptrCast(&vk_allocator.callbacks);
    init_info.PipelineRenderingCreateInfo = .{
        .sType = c.c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = @ptrCast(&format.format),
    };
    if (!c.c.cImGui_ImplVulkan_Init(&init_info)) return error.ImGuiVulkanInitFailure;
    defer c.c.cImGui_ImplVulkan_Shutdown();

    var clear_col = [4]f32{ 0.02, 0.02, 0.02, 1.0 };
    var fps: i32 = 60;
    var waits: i32 = 0;
    var frame_time: f64 = 1 / @as(f64, @floatFromInt(fps));
    var frame_start: f64 = c.c.glfwGetTime();
    var sleep_threshold: u64 = 2_300_000;

    // =============== Runloop ==================

    var refresh_swapchain: bool = false;
    while (!platform_data.window.want_close) {
        if (extent.width != platform_data.window.configured_width or extent.height != platform_data.window.configured_height) {
            refresh_swapchain = true;
            extent.width = platform_data.window.configured_width;
            extent.height = platform_data.window.configured_height;
        }

        {
            // const offset = [_]vk.DeviceSize{0};

            c.c.cImGui_ImplVulkan_NewFrame();
            // c.c.cImGui_ImplGlfw_NewFrame();
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
                c.c.ImGui_EndFrame();
                c.c.ImGui_Render();
                const draw_data = c.c.ImGui_GetDrawData();
                const is_minimized = (draw_data.*.DisplaySize.x <= 0.0 or draw_data.*.DisplaySize.y <= 0.0);
                if (!is_minimized) {
                    c.c.cImGui_ImplVulkan_RenderDrawData(draw_data, @ptrFromInt(@intFromEnum(im.cmdbuf)));
                }
            }

            {
                _ = c.c.ImGui_Begin("Settings", null, 0);
                defer c.c.ImGui_End();
                _ = c.c.ImGui_ColorEdit3("Clear Color", @ptrCast(clear_col[0..]), 0);

                if (c.c.ImGui_InputInt("fps", &fps)) {
                    frame_time = 1 / @as(f64, @floatFromInt(fps));
                }
            }

            {
                _ = c.c.ImGui_Begin("Performance", null, 0);
                defer c.c.ImGui_End();

                c.c.ImGui_Text("Time: %.3f ms/frame (%.1f FPS)", 1000.0 / io.*.Framerate, io.*.Framerate);

                if (c.c.ImGui_CollapsingHeader("Allocations", 0)) {
                    c.c.ImGui_Text(
                        "Per-Frame: A %3d, R %3d, F %3d",
                        vk_allocator.alloc_count,
                        vk_allocator.realloc_count,
                        vk_allocator.free_count,
                    );
                    c.c.ImGui_Text(
                        "Total: A %3d, M %d bytes",
                        vk_allocator.allocations.count(),
                        vk_allocator.total_size,
                    );
                }
                vk_allocator.reset_counts();
            }
        }
        try transitionImage(dev, im.cmdbuf, im.image, .general, .present_src_khr);

        try dev.endCommandBuffer(im.cmdbuf);

        const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
        const wait_semaphores = [_]vk.Semaphore{
            im.image_acquired,
        };
        const complete_semaphores = [_]vk.Semaphore{
            im.render_finished,
        };
        const buffers = [_]vk.CommandBuffer{
            im.cmdbuf,
        };
        try dev.queueSubmit(graphics_queue.handle, 1, &[_]vk.SubmitInfo{
            .{
                .wait_semaphore_count = wait_semaphores.len,
                .p_wait_semaphores = @ptrCast(&wait_semaphores),
                .p_wait_dst_stage_mask = &wait_stage,
                .command_buffer_count = buffers.len,
                .p_command_buffers = @ptrCast(&buffers),
                .signal_semaphore_count = complete_semaphores.len,
                .p_signal_semaphores = @ptrCast(&complete_semaphores),
            },
        }, im.frame_fence);

        const semaphores = [_]vk.Semaphore{
            im.render_finished,
        };

        _ = dev.queuePresentKHR(present_queue.handle, &.{
            .wait_semaphore_count = semaphores.len,
            .p_wait_semaphores = @ptrCast(&semaphores),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain),
            .p_image_indices = @ptrCast(&frame_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {},
            else => {
                return err;
            },
        };

        if (refresh_swapchain) {
            refresh_swapchain = false;
            for (swap_images) |*si| {
                si.waitForFence(dev) catch {};
            }
            try dev.deviceWaitIdle();
            dev.destroySwapchainKHR(swapchain, &vk_allocator.callbacks);
            swapchain = try createSwapchain(instance, dev, pdev, surface, extent, graphics_queue, present_queue, format, allocator, &vk_allocator.callbacks, .null_handle);

            const images = try dev.getSwapchainImagesAllocKHR(swapchain, allocator);
            defer allocator.free(images);
            for (swap_images, images) |*si, *i| {
                si.change_image(dev, i.*, format.format, &vk_allocator.callbacks) catch {};
            }
        }

        const result = try dev.acquireNextImageKHR(
            swapchain,
            std.math.maxInt(u64),
            next_image_acquired,
            .null_handle,
        );

        std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
        frame_index = result.image_index;

        if (result.result == .suboptimal_khr) {
            refresh_swapchain = true;
        }

        platform_data.poll_events();
        // c.glfwPollEvents();
        {
            const end_time = (frame_start + frame_time);
            var now: f64 = c.c.glfwGetTime();
            waits = 0;
            if (sleep_threshold == 0) sleep_threshold = 1;
            while (end_time > now) {
                const wait_time = @as(u64, @intFromFloat((end_time - now) * 1_000_000_000));
                // const smaller_threshold = @divFloor(sleep_threshold, 10);
                if (wait_time > sleep_threshold) {
                    const sub = @min(wait_time - 1, sleep_threshold * 6);
                    std.Thread.sleep(wait_time - sub);
                }
                // else if (wait_time > smaller_threshold) {
                //     std.Thread.sleep(wait_time);
                // }
                now = c.c.glfwGetTime();
                waits += 1;
            }
            frame_start = c.c.glfwGetTime();
        }
    }

    for (swap_images) |*si| {
        si.waitForFence(dev) catch {};
    }
    try dev.deviceWaitIdle();

    std.debug.print("\n== Closed ==\n", .{});
    vk_allocator.report();
    vk_allocator.reset_counts();
}

// ================== Callbacks for GLFW ====================

fn check_vk_result(err: c.c.VkResult) callconv(std.builtin.CallingConvention.c) void {
    if (err == 0) return;
    std.debug.print("[vulkan] Error: VkResult = {d}\n", .{err});
    if (err < 0) std.process.exit(1);
}

fn loader(name: [*c]const u8, instance: ?*anyopaque) callconv(std.builtin.CallingConvention.c) ?*const fn () callconv(std.builtin.CallingConvention.c) void {
    return c.glfwGetInstanceProcAddress(@enumFromInt(@intFromPtr(instance)), name);
}

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
