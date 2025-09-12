const std = @import("std");
const vk = @import("vulkan");
const platform = @import("platform");
const core = @import("core");

const c = @import("c.zig");
const vk_alloc = @import("vulkan_allocator.zig");
const mu16 = core.math.as(u16);

const callbacks = vk_alloc.callbacks;
const Allocator = std.mem.Allocator;

const required_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
const required_instance_extensions = [_][*:0]const u8{ vk.extensions.ext_debug_utils.name, vk.extensions.khr_surface.name, vk.extensions.khr_wayland_surface.name };

const ENGINE_NAME = "WorkingEngineTitle";
pub const GraphicsContextOpts = struct {
    name: []const u8,
    start_width: u16,
    start_height: u16,
};

fn loadVkFunc(T: type, name: []const u8) T {
    return gc.libvk.lookup(T, name);
}

var gc: GraphicsContext = undefined;

pub fn init(opts: GraphicsContextOpts) !void {
    gc = try GraphicsContext.init(opts);
}

pub fn deinit() void {
    gc.deinit();
}

pub fn startFrame() !void {
    const im = gc.currentFrame();
    try im.waitForFence(gc.dev);
    try gc.dev.resetFences(1, @ptrCast(&im.frame_fence));
    im.deletor.flush(gc.dev);

    try gc.dev.resetCommandBuffer(im.cmdbuf, .{});

    try gc.dev.beginCommandBuffer(im.cmdbuf, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
    });
    try transitionImage(gc.dev, im.cmdbuf, im.image, .undefined, .general);
}

pub fn resize(size: mu16.Vec2) void {
    gc.render_size.width = size.x;
    gc.render_size.height = size.y;
    gc.refresh_swapchain = true;
}

pub fn clear(color: [4]f32) void {
    const im = gc.currentFrame();
    gc.dev.cmdClearColorImage(
        im.cmdbuf,
        im.image,
        .general,
        &vk.ClearColorValue{ .float_32 = color },
        1,
        @ptrCast(&subresourceRange(.{ .color_bit = true })),
    );
}

pub fn endFrame() !void {
    const im = gc.currentFrame();

    try transitionImage(gc.dev, im.cmdbuf, im.image, .general, .present_src_khr);

    try gc.dev.endCommandBuffer(im.cmdbuf);

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
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{
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

    _ = gc.dev.queuePresentKHR(gc.present_queue.handle, &.{
        .wait_semaphore_count = semaphores.len,
        .p_wait_semaphores = @ptrCast(&semaphores),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&gc.swapchain),
        .p_image_indices = @ptrCast(&gc.frame_index),
    }) catch |err| switch (err) {
        error.OutOfDateKHR => {},
        else => {
            return err;
        },
    };

    if (gc.refresh_swapchain) {
        try refresh_swapchain();
    }
    const result = blk: {
        break :blk gc.dev.acquireNextImageKHR(
            gc.swapchain,
            std.math.maxInt(u64),
            gc.next_image_acquired,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                gc.refresh_swapchain = true;
                break :blk null;
            },
            else => {
                return err;
            },
        };
    };

    std.mem.swap(vk.Semaphore, &gc.swap_images[result.?.image_index].image_acquired, &gc.next_image_acquired);
    gc.frame_index = result.?.image_index;
    vk_alloc.reset_counts();
}

fn refresh_swapchain() !void {
    gc.refresh_swapchain = false;
    for (gc.swap_images) |*si| {
        si.waitForFence(gc.dev) catch {};
    }
    try gc.dev.deviceWaitIdle();
    gc.swapchain = try gc.createSwapchain();

    const images = try gc.dev.getSwapchainImagesAllocKHR(gc.swapchain, gc.allocator);
    defer gc.allocator.free(images);
    for (gc.swap_images, images) |*si, *i| {
        si.change_image(gc.dev, i.*, gc.format.format) catch {};
    }
}

const GraphicsContext = struct {
    allocator: Allocator,
    libvk: std.DynLib,
    load_fn: vk.PfnGetInstanceProcAddr = undefined,
    render_size: vk.Extent2D = .{ .width = 0, .height = 0 },
    vkb: *vk.BaseWrapper = undefined,
    vki: *vk.InstanceWrapper = undefined,
    vkd: *vk.DeviceWrapper = undefined,
    instance: vk.InstanceProxy = undefined,
    dev: vk.DeviceProxy = undefined,
    pdev: vk.PhysicalDevice = .null_handle,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    surface: vk.SurfaceKHR = .null_handle,
    deletor: DeletionQueue = undefined,
    graphics_queue: Queue = undefined,
    present_queue: Queue = undefined,
    format: vk.SurfaceFormatKHR = undefined,

    // Swapchain

    swapchain: vk.SwapchainKHR = .null_handle,
    frame_index: usize = 0,
    swap_images: []SwapImage = &[0]SwapImage{},
    next_image_acquired: vk.Semaphore = .null_handle,
    refresh_swapchain: bool = false,

    fn glfw_error_callback(err: c_int, description: [*c]const u8) callconv(std.builtin.CallingConvention.c) void {
        std.debug.print("GLFW Error {d}: {s}\n", .{ err, description });
    }

    pub fn init(opts: GraphicsContextOpts) !GraphicsContext {
        const allocator = core.tagged_allocator(.graphics_context);

        var ret = GraphicsContext{
            .render_size = .{
                .width = opts.start_width,
                .height = opts.start_height,
            },
            .allocator = allocator,
            // TODO: Select libvulkan properly based on platform
            // https://github.com/glfw/glfw/blob/master/src/vulkan.c#L56C1-L68C7
            //
            // #if defined(_GLFW_VULKAN_LIBRARY)
            //         _glfw.vk.handle = _glfwPlatformLoadModule(_GLFW_VULKAN_LIBRARY);
            // #elif defined(_GLFW_WIN32)
            //         _glfw.vk.handle = _glfwPlatformLoadModule("vulkan-1.dll");
            // #elif defined(_GLFW_COCOA)
            //         _glfw.vk.handle = _glfwPlatformLoadModule("libvulkan.1.dylib");
            //         if (!_glfw.vk.handle)
            //             _glfw.vk.handle = _glfwLoadLocalVulkanLoaderCocoa();
            // #elif defined(__OpenBSD__) || defined(__NetBSD__)
            //         _glfw.vk.handle = _glfwPlatformLoadModule("libvulkan.so");
            // #else
            //         _glfw.vk.handle = _glfwPlatformLoadModule("libvulkan.so.1");
            // #endif
            .libvk = try std.DynLib.open("libvulkan.so"),
        };
        try vk_alloc.init();
        ret.load_fn = ret.libvk.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr").?;
        ret.vkb = try allocator.create(vk.BaseWrapper);
        ret.vkb.* = vk.BaseWrapper.load(ret.load_fn);

        var extension_names: std.ArrayList([*:0]const u8) = .empty;
        defer extension_names.deinit(allocator);
        try extension_names.append(allocator, vk.extensions.ext_debug_utils.name);
        // the following extensions are to support vulkan in mac os
        // see https://github.com/glfw/glfw/issues/2335
        try extension_names.append(allocator, vk.extensions.khr_portability_enumeration.name);
        try extension_names.append(allocator, vk.extensions.khr_get_physical_device_properties_2.name);

        // var glfw_exts_count: u32 = 0;
        // const glfw_exts = c.glfwGetRequiredInstanceExtensions(&glfw_exts_count);
        try extension_names.appendSlice(allocator, &required_instance_extensions);

        const create_info = vk.InstanceCreateInfo{
            .p_application_info = &.{
                .p_application_name = @ptrCast(opts.name),
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
        const instance = try ret.vkb.createInstance(&create_info, callbacks);
        ret.vki = try allocator.create(vk.InstanceWrapper);
        ret.vki.* = vk.InstanceWrapper.load(instance, ret.vkb.dispatch.vkGetInstanceProcAddr.?);
        ret.instance = vk.InstanceProxy.init(instance, ret.vki);

        ret.debug_messenger = try ret.instance.createDebugUtilsMessengerEXT(&.{
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
        }, callbacks);

        ret.surface = try ret.instance.createWaylandSurfaceKHR(&vk.WaylandSurfaceCreateInfoKHR{
            .display = @ptrCast(platform.get_display()),
            .surface = @ptrCast(platform.get_surface()),
        }, callbacks);

        std.debug.print("Vulkan surface created.\n", .{});
        vk_alloc.report();
        vk_alloc.reset_counts();

        const pdevs = try ret.instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(pdevs);

        var current_candidate: ?DeviceCandidate = null;
        for (pdevs) |pdev| {
            if (try checkSuitable(ret.instance, pdev, allocator, ret.surface, current_candidate)) |candidate| {
                current_candidate = candidate;
            }
        }
        if (current_candidate == null) {
            return error.NoSuitablePhysicalDevice;
        }
        ret.pdev = current_candidate.?.pdev;
        // const props = current_candidate.?.props;

        std.debug.print("Physical device selected: {s}\n", .{std.mem.sliceTo(&current_candidate.?.props.device_name, 0)});

        const dev = try initializeCandidate(ret.instance, current_candidate.?);

        ret.vkd = try allocator.create(vk.DeviceWrapper);
        ret.vkd.* = vk.DeviceWrapper.load(dev, ret.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        ret.dev = vk.DeviceProxy.init(dev, ret.vkd);

        ret.deletor = DeletionQueue.init(allocator);

        ret.graphics_queue = Queue.init(ret.dev, current_candidate.?.queues.graphics_family);
        ret.present_queue = Queue.init(ret.dev, current_candidate.?.queues.present_family);

        // const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

        // ================== SwapChain ===================

        ret.format = try findSurfaceFormat(ret.instance, ret.pdev, ret.surface, allocator);
        ret.swapchain = try ret.createSwapchain();

        try ret.initSwapchainImages();

        ret.next_image_acquired = try ret.dev.createSemaphore(&.{}, callbacks);

        ret.frame_index = blk: {
            const result = try ret.dev.acquireNextImageKHR(ret.swapchain, std.math.maxInt(u64), ret.next_image_acquired, .null_handle);

            if (result.result == .not_ready or result.result == .timeout) {
                return error.ImageAcquireFailed;
            }
            break :blk result.image_index;
        };

        std.mem.swap(vk.Semaphore, &ret.swap_images[ret.frame_index].image_acquired, &ret.next_image_acquired);
        return ret;
    }

    pub fn deinit(self: *GraphicsContext) void {
        for (self.swap_images) |*si| {
            si.waitForFence(self.dev) catch {};
        }
        _ = self.dev.deviceWaitIdle() catch {};

        const dev = self.dev;

        dev.destroySemaphore(self.next_image_acquired, callbacks);
        for (self.swap_images) |*si| si.deinit(self.dev);
        self.allocator.free(self.swap_images);
        self.dev.destroySwapchainKHR(self.swapchain, callbacks);
        self.deletor.flush(dev);
        self.deletor.deinit();
        dev.destroyDevice(callbacks);
        self.allocator.destroy(self.vkd);
        self.instance.destroySurfaceKHR(self.surface, callbacks);
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, callbacks);
        self.instance.destroyInstance(callbacks);
        self.allocator.destroy(self.vki);
        self.allocator.destroy(self.vkb);
        vk_alloc.deinit();
    }

    fn createSwapchain(
        self: *GraphicsContext,
    ) !vk.SwapchainKHR {
        const old = self.swapchain;
        const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);
        const actual_extent = findActualExtent(caps, self.render_size);

        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        const qfi = [_]u32{ self.graphics_queue.family, self.present_queue.family };
        const sharing_mode: vk.SharingMode = if (self.graphics_queue.family != self.present_queue.family)
            .concurrent
        else
            .exclusive;

        var image_count = caps.min_image_count + 1;

        if (caps.max_image_count > 0) {
            image_count = @min(image_count, caps.max_image_count);
        }

        const info = vk.SwapchainCreateInfoKHR{
            .image_format = self.format.format,
            .image_color_space = .srgb_nonlinear_khr,
            .present_mode = try findPresentMode(self.instance, self.pdev, self.surface, self.allocator),
            .image_extent = actual_extent,
            .image_usage = .{ .transfer_dst_bit = true, .color_attachment_bit = true },
            .min_image_count = image_count,
            .surface = self.surface,
            .image_array_layers = 1,
            .image_sharing_mode = sharing_mode,
            .clipped = .true,
            .old_swapchain = old,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .pre_transform = caps.current_transform,
            .p_queue_family_indices = &qfi,
            .queue_family_index_count = qfi.len,
        };
        const handle = try self.dev.createSwapchainKHR(&info, callbacks);
        if (old != .null_handle)
            gc.dev.destroySwapchainKHR(old, callbacks);
        return handle;
    }

    fn currentFrame(self: *GraphicsContext) *SwapImage {
        return &self.swap_images[self.frame_index];
    }

    fn initSwapchainImages(self: *GraphicsContext) !void {
        const images = try self.dev.getSwapchainImagesAllocKHR(self.swapchain, self.allocator);
        defer self.allocator.free(images);

        self.swap_images = try self.allocator.alloc(SwapImage, images.len);
        errdefer self.allocator.free(self.swap_images);

        var i: usize = 0;
        errdefer for (self.swap_images[0..i]) |*si| si.deinit(self.dev);

        for (images) |image| {
            self.swap_images[i] = try SwapImage.init(self.dev, image, self.format.format, self.graphics_queue, self.allocator);
            i += 1;
        }
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

fn initializeCandidate(instance: vk.InstanceProxy, candidate: DeviceCandidate) !vk.Device {
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

    fn init(dev: vk.DeviceProxy, image: vk.Image, format: vk.Format, queue: Queue, allocator: Allocator) !SwapImage {
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
        try ret.change_image(dev, image, format);
        return ret;
    }

    /// Regenerate frame data for a new image
    pub fn change_image(self: *SwapImage, dev: vk.DeviceProxy, image: vk.Image, format: vk.Format) !void {
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

    fn deinit(self: *SwapImage, dev: vk.DeviceProxy) void {
        self.waitForFence(dev) catch return;
        _ = self.queue_frame_delete() catch unreachable;
        self.deletor.flush(dev);
        self.deletor.deinit();
        dev.destroyFence(self.frame_fence, callbacks);
        dev.destroySemaphore(self.image_acquired, callbacks);
        dev.destroySemaphore(self.render_finished, callbacks);
        dev.destroyCommandPool(self.pool, callbacks);
    }

    fn waitForFence(self: *SwapImage, dev: vk.DeviceProxy) !void {
        _ = try dev.waitForFences(1, @ptrCast(&self.frame_fence), .true, std.math.maxInt(u64));
    }
};

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

fn transitionImage(dev: vk.DeviceProxy, cmd: vk.CommandBuffer, image: vk.Image, current_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
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
    pub fn flush(self: *DeletionQueue, dev: vk.DeviceProxy) void {
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
