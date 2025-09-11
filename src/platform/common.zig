const math = @import("core").math.as(u16);

pub const PlatformInitError = error{CouldNotInitialise};

pub const PlatformOpts = struct {
    /// Name of the App
    name: []const u8,
    /// Hint for desired window size
    size_hint: math.Vec2,
};
