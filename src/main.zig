const app = @import("core").app;

pub fn main() !void {
    try app.init("Test App", 1080, 720);

    try app.run();
}
