const std = @import("std");
const core = @import("core");
const app = core.app;
const input = core.input;
const App = app.App;

fn init() app.AppInitError!void {
    std.log.info("Hello there", .{});
}

fn update(delta: f64) void {
    if (input.isButtonPressed(.up)) {
        app.setFPS(60);
    } else {
        app.setFPS(144);
    }
    if (input.wasButtonPressed(.esc)) {
        app.quit();
    }
    _ = delta;
}

fn render(delta: f64) void {
    core.renderer.clear(.{
        .x = @floatCast(delta),
        .y = 0,
        .z = if (input.justScrolled()) 1 else 0,
        .w = 1,
    });
}

fn deinit() void {
    std.log.info("Goodbye", .{});
}

pub fn main() !void {
    var my_app = App{
        .name = "Test App",
        .app_init = init,
        .app_update = update,
        .app_render = render,
        .app_deinit = deinit,
    };

    try my_app.run();
}
