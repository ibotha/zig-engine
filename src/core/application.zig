const platform = @import("platform");
const renderer = @import("renderer.zig");
const std = @import("std");
const Timer = @import("timer.zig").Timer;
const memory = @import("memory.zig");
const event = @import("event.zig");
const m16 = @import("zlm").as(u16);
const mf32 = @import("zlm").as(f32);

fn onClose(_: ?*anyopaque, _: event.Event, _: ?*anyopaque) bool {
    app_state.exec_state = .shutdown;
    return true;
}

fn onKey(_: ?*anyopaque, ev: event.Event, _: ?*anyopaque) bool {
    const key = ev.key;
    switch (key.key) {
        .up => {
            app_state.clear_color.x = if (key.pressed) 1 else 0;
        },
        .down => {
            app_state.clear_color.y = if (key.pressed) 1 else 0;
        },
        .left => {
            app_state.clear_color.z = if (key.pressed) 1 else 0;
        },
        .r => {
            if (key.pressed)
                memory.report();
        },
        .esc => {
            if (key.pressed)
                app_state.exec_state = .shutdown;
        },
        else => {
            return false;
        },
    }
    return true;
}
/// Configuration for our application.
pub const App = struct {
    name: []const u8,
    size_hint: m16.Vec2 = .{
        .x = 1080,
        .y = 720,
    },

    pub fn init(cfg: *App) !void {
        if (initialized) {
            std.log.err("Already initialised!\n", .{});
            @panic("Double initialisation.");
        }

        event.init();
        memory.init();

        initialized = true;
        // Init all engine subsystems.
        try platform.init(.{
            .name = cfg.name,
            .size_hint = cfg.size_hint,
        });

        try renderer.init(.{
            .name = cfg.name,
            .size_hint = cfg.size_hint,
        });
        try event.listen(.closed, null, onClose);
        try event.listen(.key, null, onKey);
        // app_state.width = @intCast(app_state.platform.window.configured_width);
        // app_state.height = @intCast(app_state.platform.window.configured_height);
        app_state.exec_state = .running;
        app_state.app_timer.reset();
    }

    pub fn run(_: App) !void {
        if (!initialized) {
            std.log.err("App must be initialised before running!\n", .{});
            @panic("Not initialised.");
        }
        const fps: f64 = 144;
        const desired_frame_time = 1 / fps;
        var frame_timer = Timer{};
        var current_frame: u64 = 0;
        var frame_times = [_]struct { total: f64 = 0, working: f64 = 0 }{.{}} ** 30;
        while (app_state.exec_state == .running) {
            app_state.app_timer.update();
            frame_timer.update();
            frame_times[current_frame % frame_times.len].total = frame_timer.elapsed;
            frame_timer.reset();
            try platform.poll_events();

            try renderer.startFrame();
            renderer.clear(app_state.clear_color);
            try renderer.endFrame();
            current_frame += 1;
            frame_timer.update();
            frame_times[current_frame % frame_times.len].working = frame_timer.elapsed;
            if (frame_timer.elapsed < desired_frame_time)
                platform.sleep(@max(desired_frame_time - frame_timer.elapsed - 0.00007, 0));
        }
        memory.report();
        var total: f64 = 0;
        var working: f64 = 0;
        for (frame_times) |f| {
            total += f.total;
            working += f.working;
        }
        const frame_time = total / @as(f64, @floatFromInt(frame_times.len));
        const working_frame_time = working / @as(f64, @floatFromInt(frame_times.len));
        std.log.debug("Average frame time {d:.4}s ({d:.2} fps)", .{ frame_time, 1 / frame_time });
        std.log.debug("Average working time {d:.4}s/{d:.4}s ({d:.1}%)", .{ working_frame_time, desired_frame_time, working_frame_time * 100.0 / desired_frame_time });
        deinit();
    }
};

const AppState = struct {
    /// State of the application lifecycle
    exec_state: ExecState = .startup,
    /// Width of the application surface if applicable
    width: u16 = 0,
    /// Height of the application surface if applicable
    height: u16 = 0,
    /// Last time measured from the start of the application in seconds
    app_timer: Timer = .{},

    clear_color: mf32.Vec4 = .{ .x = 1, .y = 1, .z = 1, .w = 1 },

    const ExecState = enum {
        startup,
        running,
        suspended,
        shutdown,
    };
};

var app_state = AppState{};

var initialized = false;

fn deinit() void {
    renderer.deinit();
    platform.deinit();
    std.log.debug("App ran for {d}s\n", .{app_state.app_timer.elapsed});
    event.deinit();
    memory.report();
    memory.deinit();
}
