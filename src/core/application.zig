const platform = @import("platform");
const renderer = @import("renderer.zig");
const std = @import("std");
const Timer = @import("timer.zig").Timer;
const memory = @import("memory.zig");
const event = @import("event.zig");
const input = @import("input.zig");
const m16 = @import("zlm").as(u16);
const mf32 = @import("zlm").as(f32);

fn onClose(_: ?*anyopaque, _: event.Event, _: ?*anyopaque) bool {
    app_state.exec_state = .shutdown;
    return true;
}

pub const AppUpdateError = error{Crash};
pub const AppInitError = error{BadInit};

/// Configuration for our application.
pub const App = struct {
    name: []const u8,
    size_hint: m16.Vec2 = .{
        .x = 1080,
        .y = 720,
    },
    app_init: *const fn () AppInitError!void,
    app_update: *const fn (f64) void,
    app_render: *const fn (f64) void,
    app_deinit: *const fn () void,

    fn init(cfg: *App) !void {
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
        try input.init();
        try event.listen(.closed, null, onClose);
        // app_state.width = @intCast(app_state.platform.window.configured_width);
        // app_state.height = @intCast(app_state.platform.window.configured_height);
        app_state.exec_state = .running;
        app_state.app_timer.reset();
        try cfg.app_init();
    }

    pub fn run(app: *App) !void {
        try app.init();
        if (!initialized) {
            std.log.err("App must be initialised before running!\n", .{});
            @panic("Not initialised.");
        }
        var frame_timer = Timer{};
        var current_frame: u64 = 0;
        var frame_times = [_]struct { total: f64 = 0, working: f64 = 0 }{.{}} ** 30;
        while (app_state.exec_state == .running) {
            // Frame time tracking
            app_state.app_timer.update();
            frame_timer.update();
            const delta_time = frame_timer.elapsed;
            frame_timer.reset();
            frame_times[current_frame % frame_times.len].total = delta_time;

            // Update various systems
            app.app_update(delta_time);
            input.update(delta_time);
            try platform.poll_events();

            // TODO: instrument the various stages of frame computation
            // Render point
            try renderer.startFrame();
            renderer.clear(app_state.clear_color);
            app.app_render(delta_time);
            try renderer.endFrame();

            // Mark the working time of the frame
            current_frame += 1;
            frame_timer.update();
            frame_times[current_frame % frame_times.len].working = frame_timer.elapsed;

            // Give a little back to the CPU, shame it works so hard...
            if (frame_timer.elapsed < app_state.desired_frame_time)
                platform.sleep(@max(app_state.desired_frame_time - frame_timer.elapsed - 0.00007, 0));
        }
        app.app_deinit();
        {
            var total: f64 = 0;
            var working: f64 = 0;
            for (frame_times) |f| {
                total += f.total;
                working += f.working;
            }
            const frame_time = total / @as(f64, @floatFromInt(frame_times.len));
            const working_frame_time = working / @as(f64, @floatFromInt(frame_times.len));
            std.log.debug("Average frame time {d:.4}s ({d:.2} fps)", .{ frame_time, 1 / frame_time });
            std.log.debug("Average working time {d:.4}s/{d:.4}s ({d:.1}%)", .{
                working_frame_time,
                app_state.desired_frame_time,
                working_frame_time * 100.0 / app_state.desired_frame_time,
            });
        }
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
    desired_frame_time: f64 = 1.0 / 144.0,

    const ExecState = enum {
        startup,
        running,
        suspended,
        shutdown,
    };
};

var app_state = AppState{};

var initialized = false;

pub fn setFPS(fps: u32) void {
    app_state.desired_frame_time = 1.0 / @as(f64, @floatFromInt(fps));
}
pub fn quit() void {
    app_state.exec_state = .shutdown;
}

fn deinit() void {
    if (!initialized) {
        std.log.err("App must be initialised before deinit!\n", .{});
        @panic("Not initialised.");
    }
    input.deinit();
    renderer.deinit();
    platform.deinit();
    std.log.debug("App ran for {d}s\n", .{app_state.app_timer.elapsed});
    event.deinit();
    memory.report();
    memory.deinit();
}
