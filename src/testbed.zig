const std = @import("std");
const platform = @import("platform");
const Platform = platform.Platform;
const core = @import("core");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) {
        @panic("Leak detected in engine");
    };
    const allocator = gpa.allocator();

    const platform_data = Platform.init(allocator, .{
        .name = "TestBed",
        .size_hint = .{ .x = 1080, .y = 720 },
    }) catch |err| {
        std.log.err("Could not init platform! {any}", .{err});
        std.process.exit(1);
    };
    defer platform_data.deinit(allocator);
}
