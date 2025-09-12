const backend = @import("renderer_backend");
const zlm = @import("zlm");
const mu16 = zlm.as(u16);
const mf32 = zlm.as(f32);
const std = @import("std");
const event = @import("event.zig");

pub const RendererOpts = struct { name: []const u8, size_hint: mu16.Vec2 };

fn onResize(_: ?*anyopaque, ev: event.Event, _: ?*anyopaque) bool {
    backend.resize(ev.resize);
    return true;
}

pub fn init(opts: RendererOpts) !void {
    try backend.init(.{
        .name = opts.name,
        .start_height = opts.size_hint.x,
        .start_width = opts.size_hint.y,
    });

    try event.listen(.resize, null, onResize);
}
pub fn deinit() void {
    backend.deinit();
}

pub fn startFrame() !void {
    try backend.startFrame();
}

pub fn endFrame() !void {
    try backend.endFrame();
}

fn normToByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v * 255, 0, 255.999));
}

pub fn clear(color: mf32.Vec4) void {
    backend.clear(std.mem.bytesAsValue([4]f32, std.mem.asBytes(&color)).*);
}
