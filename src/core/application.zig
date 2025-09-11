const platform = @import("platform");
const std = @import("std");

const App = struct {
    /// State of the application lifecycle
    exec_state: ExecState = .startup,
    /// Width of the application surface if applicable
    width: u16 = 0,
    /// Height of the application surface if applicable
    height: u16 = 0,
    /// Last time measured from the start of the application in seconds
    last_time: f64 = 0,

    gpa: std.heap.GeneralPurposeAllocator(.{}),
    const ExecState = enum {
        startup,
        running,
        suspended,
        shutdown,
    };
};

var app_state = App{
    .gpa = .init,
};

var initialized = false;

pub fn init(name: []const u8, width: u16, height: u16) !void {
    const allocator = app_state.gpa.allocator();
    if (initialized) {
        std.log.err("Already initialised!\n", .{});
        @panic("Double initialisation.");
    }
    initialized = true;
    // Init all engine subsystems.
    try platform.init(allocator, .{
        .name = name,
        .size_hint = .{ .x = width, .y = height },
    });
    // app_state.width = @intCast(app_state.platform.window.configured_width);
    // app_state.height = @intCast(app_state.platform.window.configured_height);
    app_state.exec_state = .running;
}

pub fn run() !void {
    while (app_state.exec_state == .running) {
        try platform.poll_events();

        if (platform.want_close()) {
            app_state.exec_state = .shutdown;
        }
        std.Thread.sleep(1_000_000);
    }

    deinit();
}

fn deinit() void {
    platform.deinit();
    if (app_state.gpa.deinit() == .leak) {
        @panic("Leak detected in engine");
    }
}
