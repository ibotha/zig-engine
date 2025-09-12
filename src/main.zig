const App = @import("core").app.App;

pub fn main() !void {
    var app = App{
        .name = "Test App",
    };
    try app.init();

    try app.run();
}
