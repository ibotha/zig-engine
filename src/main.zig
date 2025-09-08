const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;

const APP_NAME = "WorkingAppTitle";
const ENGINE_NAME = "WorkingEngineTitle";

const required_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

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
    c.glfwWindowHint(c.c.GLFW_RESIZABLE, c.GLFW_TRUE);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        APP_NAME,
        null,
        null,
    );
    if (window == null) return error.WindowNotCreated;
    defer c.glfwDestroyWindow(window);

    _ = c.glfwSetKeyCallback(window, key_callback);

    // ============= Vulkan ==============
    const vk_allocator = try VkAllocator.init(allocator);
    defer vk_allocator.deinit();

    const vkb = vk.BaseWrapper.load(c.glfwGetInstanceProcAddress);

    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);
    try extension_names.append(allocator, vk.extensions.ext_debug_utils.name);
    // the following extensions are to support vulkan in mac os
    // see https://github.com/glfw/glfw/issues/2335
    try extension_names.append(allocator, vk.extensions.khr_portability_enumeration.name);
    try extension_names.append(allocator, vk.extensions.khr_get_physical_device_properties_2.name);

    var glfw_exts_count: u32 = 0;
    const glfw_exts = c.glfwGetRequiredInstanceExtensions(&glfw_exts_count);
    try extension_names.appendSlice(allocator, @ptrCast(glfw_exts[0..glfw_exts_count]));

    const create_info = vk.InstanceCreateInfo{
        .p_application_info = &.{
            .p_application_name = APP_NAME,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = ENGINE_NAME,
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        },
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,
        .enabled_layer_count = 1,
        .pp_enabled_layer_names = &required_layers,
        // enumerate_portability_bit_khr to support vulkan in mac os
        // see https://github.com/glfw/glfw/issues/2335
        .flags = .{ .enumerate_portability_bit_khr = true },
    };
    const instance_raw = try vkb.createInstance(&create_info, &vk_allocator.callbacks);
    const vki = try allocator.create(vk.InstanceWrapper);
    defer allocator.destroy(vki);
    vki.* = vk.InstanceWrapper.load(instance_raw, vkb.dispatch.vkGetInstanceProcAddr.?);
    const instance = vk.InstanceProxy.init(instance_raw, vki);
    defer instance.destroyInstance(&vk_allocator.callbacks);

    const debug_messenger = try instance.createDebugUtilsMessengerEXT(&.{
        .message_severity = .{
            //.verbose_bit_ext = true,
            //.info_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = &debugUtilsMessengerCallback,
        .p_user_data = null,
    }, &vk_allocator.callbacks);
    instance.destroyDebugUtilsMessengerEXT(debug_messenger, &vk_allocator.callbacks);

    std.debug.print("Vulkan instance created.\n", .{});
    vk_allocator.report();
    vk_allocator.reset_counts();
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance.handle, window.?, &vk_allocator.callbacks, &surface) != .success) {
        return error.SurfaceInitFailed;
    }
    defer instance.destroySurfaceKHR(surface, &vk_allocator.callbacks);

    std.debug.print("Vulkan surface created.\n", .{});
    vk_allocator.report();
    vk_allocator.reset_counts();

    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    const tmp = pdevs[0];
    pdevs[0] = pdevs[1];
    pdevs[1] = tmp;
    defer allocator.free(pdevs);

    var current_candidate: ?DeviceCandidate = null;
    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface, current_candidate)) |candidate| {
            current_candidate = candidate;
        }
    }
    if (current_candidate == null) {
        return error.NoSuitablePhysicalDevice;
    }
    const pdev = current_candidate.?.pdev;
    // const props = current_candidate.?.props;

    std.debug.print("Physical device selected: {s}\n", .{std.mem.sliceTo(&current_candidate.?.props.device_name, 0)});

    const raw_dev = try initializeCandidate(instance, current_candidate.?, &vk_allocator.callbacks);

    const vkd = try allocator.create(vk.DeviceWrapper);
    defer allocator.destroy(vkd);
    vkd.* = vk.DeviceWrapper.load(raw_dev, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    const dev = vk.DeviceProxy.init(raw_dev, vkd);
    defer dev.destroyDevice(&vk_allocator.callbacks);
    std.debug.print("Vulkan device created.\n", .{});
    vk_allocator.report();
    vk_allocator.reset_counts();

    var deletor = DeletionQueue.init(allocator);
    defer deletor.deinit();
    defer deletor.flush(&dev, &vk_allocator.callbacks);

    const graphics_queue = Queue.init(dev, current_candidate.?.queues.graphics_family);
    const present_queue = Queue.init(dev, current_candidate.?.queues.present_family);

    // const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

    // ================== SwapChain ===================

    const format = try findSurfaceFormat(instance, pdev, surface, allocator);
    var swapchain = try createSwapchain(&instance, &dev, pdev, surface, extent, graphics_queue, present_queue, format, allocator, &vk_allocator.callbacks, .null_handle);
    defer dev.destroySwapchainKHR(swapchain, &vk_allocator.callbacks);

    var swap_images = try initSwapchainImages(&dev, swapchain, format.format, graphics_queue, allocator, &vk_allocator.callbacks);
    defer allocator.free(swap_images);
    defer for (swap_images) |*si| si.deinit(&dev, &vk_allocator.callbacks);

    var next_image_acquired = try dev.createSemaphore(&.{}, &vk_allocator.callbacks);
    defer dev.destroySemaphore(next_image_acquired, &vk_allocator.callbacks);

    var frame_index = blk: {
        const result = try dev.acquireNextImageKHR(swapchain, std.math.maxInt(u64), next_image_acquired, .null_handle);

        if (result.result == .not_ready or result.result == .timeout) {
            return error.ImageAcquireFailed;
        }
        break :blk result.image_index;
    };

    std.mem.swap(vk.Semaphore, &swap_images[frame_index].image_acquired, &next_image_acquired);

    std.debug.print("\n== Swapchain created ==\n", .{});
    vk_allocator.report();
    vk_allocator.reset_counts();

    // =============== ImGui ====================

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
    const descriptorPool = try dev.createDescriptorPool(&pool_info, &vk_allocator.callbacks);
    defer dev.destroyDescriptorPool(descriptorPool, &vk_allocator.callbacks);

    // Setup Platform/Renderer backends
    if (!c.c.cImGui_ImplGlfw_InitForVulkan(window, true)) return error.ImGuiGlfwInitForVulkanFailure;
    defer c.c.cImGui_ImplGlfw_Shutdown();
    var init_info = c.c.ImGui_ImplVulkan_InitInfo{};
    init_info.Instance = @ptrFromInt(@intFromEnum(instance.handle));
    init_info.PhysicalDevice = @ptrFromInt(@intFromEnum(pdev));
    init_info.Device = @ptrFromInt(@intFromEnum(dev.handle));
    init_info.Queue = @ptrFromInt(@intFromEnum(graphics_queue.handle));
    init_info.RenderPass = null;
    init_info.DescriptorPool = @ptrFromInt(@intFromEnum(descriptorPool));
    init_info.MinImageCount = 4;
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

    // =============== Runloop ==================
    var refresh_swapchain: bool = false;
    while (c.glfwWindowShouldClose(window) == 0) {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);

        if (extent.width != @as(u32, @intCast(w)) or extent.height != @as(u32, @intCast(h))) {
            refresh_swapchain = true;
            extent.width = @intCast(w);
            extent.height = @intCast(h);
        }

        const im = &swap_images[frame_index];

        try im.waitForFence(&dev);
        try dev.resetFences(1, @ptrCast(&im.frame_fence));
        im.deletor.flush(&dev, &vk_allocator.callbacks);

        try dev.resetCommandBuffer(im.cmdbuf, .{});

        try dev.beginCommandBuffer(im.cmdbuf, &vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        });

        try transitionImage(&dev, im.cmdbuf, im.image, .undefined, .general);
        dev.cmdClearColorImage(
            im.cmdbuf,
            im.image,
            .general,
            &vk.ClearColorValue{ .float_32 = .{ 1.0, 0.8, 0.2, 1.0 } },
            1,
            @ptrCast(&subresourceRange(.{ .color_bit = true })),
        );
        {
            // const offset = [_]vk.DeviceSize{0};

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
                c.c.ImGui_EndFrame();
                c.c.ImGui_Render();
                const draw_data = c.c.ImGui_GetDrawData();
                const is_minimized = (draw_data.*.DisplaySize.x <= 0.0 or draw_data.*.DisplaySize.y <= 0.0);
                if (!is_minimized) {
                    c.c.cImGui_ImplVulkan_RenderDrawData(draw_data, @ptrFromInt(@intFromEnum(im.cmdbuf)));
                }
            }

            {
                _ = c.c.ImGui_Begin("Hello, world!", null, 0);
                defer c.c.ImGui_End();

                c.c.ImGui_Text("Position");

                c.c.ImGui_Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / io.*.Framerate, io.*.Framerate);
                c.c.ImGui_Text("Allocations %d", vk_allocator.alloc_count);
                c.c.ImGui_Text("Re-Allocations %d", vk_allocator.realloc_count);
                c.c.ImGui_Text("Frees %d", vk_allocator.free_count);
                vk_allocator.reset_counts();
            }
        }
        try transitionImage(&dev, im.cmdbuf, im.image, .general, .present_src_khr);

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

        _ = try dev.queuePresentKHR(present_queue.handle, &.{
            .wait_semaphore_count = semaphores.len,
            .p_wait_semaphores = @ptrCast(&semaphores),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain),
            .p_image_indices = @ptrCast(&frame_index),
        });

        if (refresh_swapchain) {
            refresh_swapchain = false;
            for (swap_images) |*si| {
                si.waitForFence(&dev) catch {};
            }
            try dev.deviceWaitIdle();
            dev.destroySwapchainKHR(swapchain, &vk_allocator.callbacks);
            swapchain = try createSwapchain(&instance, &dev, pdev, surface, extent, graphics_queue, present_queue, format, allocator, &vk_allocator.callbacks, .null_handle);

            const images = try dev.getSwapchainImagesAllocKHR(swapchain, allocator);
            defer allocator.free(images);
            for (swap_images, images) |*si, *i| {
                si.change_image(&dev, i.*, format.format, &vk_allocator.callbacks) catch {};
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

        c.glfwPollEvents();
    }

    for (swap_images) |*si| {
        si.waitForFence(&dev) catch {};
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

// =================== VK Allocator =========================

const Allocation = struct {
    size: usize,
    alignment: std.mem.Alignment,
    scope: vk.SystemAllocationScope,
};

const VkAllocator = struct {
    allocator: Allocator,
    allocations: std.AutoHashMap(?*anyopaque, Allocation),
    callbacks: vk.AllocationCallbacks,
    alloc_count: usize,
    realloc_count: usize,
    free_count: usize,

    pub fn init(allocator: Allocator) !*VkAllocator {
        var self: *VkAllocator = try allocator.create(VkAllocator);
        self.allocator = allocator;
        self.allocations = .init(allocator);
        self.callbacks = .{
            .p_user_data = @ptrCast(self),
            .pfn_allocation = allocate,
            .pfn_reallocation = reallocate,
            .pfn_free = free,
        };
        self.alloc_count = 0;
        self.realloc_count = 0;
        self.free_count = 0;
        return self;
    }

    pub fn deinit(self: *VkAllocator) void {
        std.debug.print("Deinit\n", .{});
        self.report();
        self.allocations.clearAndFree();
        self.allocator.destroy(self);
    }

    fn allocate(p_user_data: ?*anyopaque, size: usize, raw_alignment: usize, scope: vk.SystemAllocationScope) callconv(.c) ?*anyopaque {
        const self: *VkAllocator = @ptrCast(@alignCast(p_user_data));
        const alignment = std.mem.Alignment.fromByteUnits(raw_alignment);
        const ret = self.allocator.rawAlloc(size, alignment, @returnAddress());

        self.allocations.put(ret, .{
            .size = size,
            .alignment = alignment,
            .scope = scope,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                std.debug.print("Out of memory while allocating {d} bytes\n", .{size});
                return null;
            },
        };
        self.alloc_count += 1;
        return @ptrCast(ret);
    }

    fn reallocate(p_user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, raw_alignment: usize, scope: vk.SystemAllocationScope) callconv(.c) ?*anyopaque {
        const self: *VkAllocator = @ptrCast(@alignCast(p_user_data));
        const allocation = self.allocations.get(ptr) orelse {
            return null;
        };

        const ret = allocate(p_user_data, size, raw_alignment, scope);
        const copy_len = @min(size, allocation.size);
        const cast_ptr: [*c]u8 = @ptrCast(ptr);
        const cast_ret: [*c]u8 = @ptrCast(ret);
        @memcpy(cast_ret[0..copy_len], cast_ptr[0..copy_len]);
        free(p_user_data, ptr);
        self.realloc_count += 1;
        self.alloc_count -= 1;
        self.free_count -= 1;
        return @ptrCast(ret);
    }

    fn free(p_user_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        const self: *VkAllocator = @ptrCast(@alignCast(p_user_data));
        const allocation = self.allocations.get(ptr) orelse {
            std.debug.print("Freeing unknown ptr {any} in VkAllocator\n", .{ptr});
            return;
        };
        const cast_ptr: [*c]u8 = @ptrCast(ptr);
        self.allocator.rawFree(cast_ptr[0..allocation.size], allocation.alignment, @returnAddress());
        _ = self.allocations.remove(ptr);
        self.free_count += 1;
    }

    pub fn reset_counts(self: *VkAllocator) void {
        self.alloc_count = 0;
        self.realloc_count = 0;
        self.free_count = 0;
    }

    pub fn report(self: *const VkAllocator) void {
        var it = self.allocations.keyIterator();
        var total_mem: usize = 0;
        var total_allocs: usize = 0;
        while (it.next()) |k| {
            const allocation = self.allocations.get(k.*).?;
            total_mem += allocation.size;
            total_allocs += 1;
        }
        std.debug.print("{} allocations.\n", .{self.alloc_count});
        std.debug.print("{} reallocations.\n", .{self.realloc_count});
        std.debug.print("{} frees.\n", .{self.free_count});
        std.debug.print("Total memory usage: {} bytes over {} allocations\n", .{ total_mem, total_allocs });
    }
};

fn debugUtilsMessengerCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, msg_type: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) vk.Bool32 {
    const severity_str = if (severity.verbose_bit_ext) "verbose" else if (severity.info_bit_ext) "info" else if (severity.warning_bit_ext) "warning" else if (severity.error_bit_ext) "error" else "unknown";

    const type_str = if (msg_type.general_bit_ext) "general" else if (msg_type.validation_bit_ext) "validation" else if (msg_type.performance_bit_ext) "performance" else if (msg_type.device_address_binding_bit_ext) "device addr" else "unknown";

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.p_message else "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message:\n  {s}\n", .{ severity_str, type_str, message });

    return .false;
}

// ================ Physical Device Selection ===============

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: vk.DeviceProxy, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

fn initializeCandidate(instance: vk.InstanceProxy, candidate: DeviceCandidate, callbacks: ?*const vk.AllocationCallbacks) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    var vk_13_features = vk.PhysicalDeviceVulkan13Features{
        .dynamic_rendering = .true,
        .synchronization_2 = .true,
    };

    var vk_12_features = vk.PhysicalDeviceVulkan12Features{
        .buffer_device_address = .true,
        .descriptor_indexing = .true,
        .p_next = @ptrCast(&vk_13_features),
    };
    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_next = @ptrCast(&vk_12_features),
    }, callbacks);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn checkSuitable(
    instance: vk.InstanceProxy,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
    current: ?DeviceCandidate,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        if (current == null or props.limits.max_per_stage_resources > current.?.props.limits.max_per_stage_resources) {
            return DeviceCandidate{
                .pdev = pdev,
                .props = props,
                .queues = allocation,
            };
        } else {
            return null;
        }
    }

    return null;
}
fn allocateQueues(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == .true) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: vk.InstanceProxy,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

// =============== SwapChain ============

fn createSwapchain(
    instance: *const vk.InstanceProxy,
    dev: *const vk.DeviceProxy,
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    extent: vk.Extent2D,
    graphics_queue: Queue,
    present_queue: Queue,
    format: vk.SurfaceFormatKHR,
    allocator: Allocator,
    callbacks: *vk.AllocationCallbacks,
    old: vk.SwapchainKHR,
) !vk.SwapchainKHR {
    const caps = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(pdev, surface);
    const actual_extent = findActualExtent(caps, extent);

    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const qfi = [_]u32{ graphics_queue.family, present_queue.family };
    const sharing_mode: vk.SharingMode = if (graphics_queue.family != present_queue.family)
        .concurrent
    else
        .exclusive;

    var image_count = caps.min_image_count + 1;

    if (caps.max_image_count > 0) {
        image_count = @min(image_count, caps.max_image_count);
    }

    const info = vk.SwapchainCreateInfoKHR{
        .image_format = format.format,
        .image_color_space = .srgb_nonlinear_khr,
        .present_mode = try findPresentMode(instance.*, pdev, surface, allocator),
        .image_extent = actual_extent,
        .image_usage = .{ .transfer_dst_bit = true, .color_attachment_bit = true },
        .min_image_count = image_count,
        .surface = surface,
        .image_array_layers = 1,
        .image_sharing_mode = sharing_mode,
        .clipped = .true,
        .old_swapchain = old,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .pre_transform = caps.current_transform,
        .p_queue_family_indices = &qfi,
        .queue_family_index_count = qfi.len,
    };
    const handle = try dev.createSwapchainKHR(&info, callbacks);
    return handle;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,
    pool: vk.CommandPool,
    cmdbuf: vk.CommandBuffer,
    deletor: DeletionQueue,

    fn init(dev: *const vk.DeviceProxy, image: vk.Image, format: vk.Format, queue: Queue, allocator: Allocator, callbacks: *vk.AllocationCallbacks) !SwapImage {
        const pool_info = vk.CommandPoolCreateInfo{
            .queue_family_index = queue.family,
            .flags = .{ .reset_command_buffer_bit = true },
        };
        const pool = try dev.createCommandPool(&pool_info, callbacks);

        var cmdbufs: [1]vk.CommandBuffer = undefined;
        const cbuf_info = vk.CommandBufferAllocateInfo{
            .command_buffer_count = 1,
            .command_pool = pool,
            .level = .primary,
        };
        try dev.allocateCommandBuffers(&cbuf_info, &cmdbufs);

        var ret: SwapImage = undefined;

        const image_acquired = try dev.createSemaphore(&.{}, callbacks);
        errdefer dev.destroySemaphore(image_acquired, callbacks);

        const render_finished = try dev.createSemaphore(&.{}, callbacks);
        errdefer dev.destroySemaphore(render_finished, callbacks);

        const frame_fence = try dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, callbacks);
        errdefer dev.destroyFence(frame_fence, callbacks);
        ret.image_acquired = image_acquired;
        ret.render_finished = render_finished;
        ret.frame_fence = frame_fence;
        ret.pool = pool;
        ret.cmdbuf = cmdbufs[0];
        ret.deletor = .init(allocator);
        ret.view = .null_handle;
        try ret.change_image(dev, image, format, callbacks);
        return ret;
    }

    /// Regenerate frame data for a new image
    pub fn change_image(self: *SwapImage, dev: *const vk.DeviceProxy, image: vk.Image, format: vk.Format, callbacks: *vk.AllocationCallbacks) !void {
        if (self.view != .null_handle) {
            try self.deletor.queue(self.view);
        }
        const view = try dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, callbacks);
        errdefer dev.destroyImageView(view, callbacks);

        self.image = image;
        self.view = view;
    }

    fn queue_frame_delete(self: *SwapImage) !void {
        try self.deletor.queue(self.view);
    }

    fn deinit(self: *SwapImage, dev: *const vk.DeviceProxy, callbacks: *vk.AllocationCallbacks) void {
        self.waitForFence(dev) catch return;
        _ = self.queue_frame_delete() catch unreachable;
        self.deletor.flush(dev, callbacks);
        self.deletor.deinit();
        dev.destroyFence(self.frame_fence, callbacks);
        dev.destroySemaphore(self.image_acquired, callbacks);
        dev.destroySemaphore(self.render_finished, callbacks);
        dev.destroyCommandPool(self.pool, callbacks);
    }

    fn waitForFence(self: *SwapImage, dev: *const vk.DeviceProxy) !void {
        _ = try dev.waitForFences(1, @ptrCast(&self.frame_fence), .true, std.math.maxInt(u64));
    }
};

fn initSwapchainImages(dev: *const vk.DeviceProxy, swapchain: vk.SwapchainKHR, format: vk.Format, queue: Queue, allocator: Allocator, callbacks: *vk.AllocationCallbacks) ![]SwapImage {
    const images = try dev.getSwapchainImagesAllocKHR(swapchain, allocator);
    defer allocator.free(images);

    var swap_images = try allocator.alloc(SwapImage, images.len);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |*si| si.deinit(dev, callbacks);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(dev, image, format, queue, allocator, callbacks);
        i += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdev, surface, allocator);
    defer allocator.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

fn findPresentMode(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR, allocator: Allocator) !vk.PresentModeKHR {
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdev, surface, allocator);
    defer allocator.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

// ==================== Dynamic Rendering =================

fn transitionImage(dev: *const vk.DeviceProxy, cmd: vk.CommandBuffer, image: vk.Image, current_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
    const image_memory_barriers = [_]vk.ImageMemoryBarrier2{
        .{
            .image = image,
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
            .old_layout = current_layout,
            .new_layout = new_layout,
            .subresource_range = subresourceRange(if (new_layout == .depth_attachment_optimal) .{ .depth_bit = true } else .{ .color_bit = true }),
            .src_queue_family_index = 0,
            .dst_queue_family_index = 0,
        },
    };

    dev.cmdPipelineBarrier2(cmd, &vk.DependencyInfo{
        .image_memory_barrier_count = image_memory_barriers.len,
        .p_image_memory_barriers = @ptrCast(&image_memory_barriers),
    });
}

fn subresourceRange(mask: vk.ImageAspectFlags) vk.ImageSubresourceRange {
    return .{
        .aspect_mask = mask,
        .base_mip_level = 0,
        .base_array_layer = 0,
        .layer_count = vk.REMAINING_ARRAY_LAYERS,
        .level_count = vk.REMAINING_MIP_LEVELS,
    };
}

// ============================ Deletion Queue ====================

// TODO: Find a way to use comptime to reduce repetition here.
const DeletionQueue = struct {
    buffers: std.ArrayList(vk.Buffer) = .empty,
    images: std.ArrayList(vk.Image) = .empty,
    swapchains: std.ArrayList(vk.SwapchainKHR) = .empty,
    imageviews: std.ArrayList(vk.ImageView) = .empty,
    semaphores: std.ArrayList(vk.Semaphore) = .empty,
    fences: std.ArrayList(vk.Fence) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) DeletionQueue {
        return .{
            .allocator = allocator,
        };
    }

    /// Free the deletion queue itself, remember to flush first.
    pub fn deinit(self: *DeletionQueue) void {
        self.buffers.clearAndFree(self.allocator);
        self.swapchains.clearAndFree(self.allocator);
        self.images.clearAndFree(self.allocator);
        self.imageviews.clearAndFree(self.allocator);
        self.semaphores.clearAndFree(self.allocator);
        self.fences.clearAndFree(self.allocator);
    }

    pub fn queue(self: *DeletionQueue, vk_elem: anytype) !void {
        switch (@TypeOf(vk_elem)) {
            vk.Buffer => {
                try self.buffers.append(self.allocator, vk_elem);
            },
            vk.Image => {
                try self.images.append(self.allocator, vk_elem);
            },
            vk.SwapchainKHR => {
                try self.swapchains.append(self.allocator, vk_elem);
            },
            vk.ImageView => {
                try self.imageviews.append(self.allocator, vk_elem);
            },
            vk.Semaphore => {
                try self.semaphores.append(self.allocator, vk_elem);
            },
            vk.Fence => {
                try self.fences.append(self.allocator, vk_elem);
            },
            else => {
                @compileError("Attempted to queue unsupported type");
            },
        }
    }

    /// Flush deletion queue, queues retain their maximum capacity for performance reasons.
    pub fn flush(self: *DeletionQueue, dev: *const vk.DeviceProxy, callbacks: *vk.AllocationCallbacks) void {
        for (self.buffers.items) |b| dev.destroyBuffer(b, callbacks);
        self.buffers.clearRetainingCapacity();
        for (self.fences.items) |f| dev.destroyFence(f, callbacks);
        self.fences.clearRetainingCapacity();
        for (self.semaphores.items) |s| dev.destroySemaphore(s, callbacks);
        self.semaphores.clearRetainingCapacity();
        for (self.imageviews.items) |iv| dev.destroyImageView(iv, callbacks);
        self.imageviews.clearRetainingCapacity();
        for (self.images.items) |i| dev.destroyImage(i, callbacks);
        self.images.clearRetainingCapacity();
        for (self.swapchains.items) |s| dev.destroySwapchainKHR(s, callbacks);
        self.swapchains.clearRetainingCapacity();
    }
};
