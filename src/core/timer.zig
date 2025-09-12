const platform = @import("platform");

pub const Timer = struct {
    /// Start time on nanoseconds
    start: i128 = 0,
    /// Cached elapsed time in seconds must call update for this to be valid
    elapsed: f64 = 0,
    /// Now in nanoseconds since epoch
    now: i128 = 0,

    /// Reset the timer's start point to now.
    pub fn reset(
        self: *Timer,
    ) void {
        self.start = platform.get_absolute_time();
        self.now = self.start;
        self.elapsed = 0;
    }

    /// Update the cached time using a value for now in seconds.
    ///
    /// Allows measuring the time once to update multiple timers.
    pub fn update(self: *Timer) void {
        self.now = platform.get_absolute_time();
        self.elapsed = @as(f64, @floatFromInt(self.now - self.start)) * 0.000000001;
    }
};
