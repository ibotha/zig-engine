pub const c = @cImport({
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_vulkan.h");
});

const vk = @import("vulkan");
