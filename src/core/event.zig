const zlm = @import("zlm").as(u16);
const tagged_allocator = @import("memory.zig").tagged_allocator;
const std = @import("std");

pub const Button = enum(u8) {
    mouse_left,
    mouse_right,
    mouse_middle,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    tab,
    space,
    esc,
    enter,
    backspace,
    num_1,
    num_2,
    num_3,
    num_4,
    num_5,
    num_6,
    num_7,
    num_8,
    num_9,
    num_0,
    left,
    up,
    down,
    right,
    unknown,
};

pub const EventType = enum(u3) {
    mouse_moved,
    mouse_scroll,
    resize,
    button,
    closed,
};

pub const Event = union(EventType) {
    mouse_moved: zlm.Vec2,
    mouse_scroll: zlm.Vec2,
    resize: zlm.Vec2,
    button: struct { button: Button, pressed: bool },
    closed: void,
};

const Registration = struct {
    callback: EventFn,
    listener: ?*anyopaque,
};

var registrations = [1]std.ArrayList(Registration){.empty} ** @typeInfo(EventType).@"enum".fields.len;

var allocator: std.mem.Allocator = undefined;
pub const EventFn = *const fn (listener: ?*anyopaque, Event, sender: ?*anyopaque) bool;

pub fn init() void {
    std.log.debug("Size of event {d}", .{@sizeOf(Event)});
    allocator = tagged_allocator(.events);
}

pub fn deinit() void {
    for (&registrations) |*r| {
        r.clearAndFree(allocator);
    }
}

pub fn listen(etype: EventType, listener: ?*anyopaque, fun: EventFn) !void {
    try registrations[@intFromEnum(etype)].append(allocator, .{ .callback = fun, .listener = listener });
}
pub fn unlisten(etype: EventType, listener: ?*anyopaque, fun: EventFn) void {
    const index = for (registrations[@intFromEnum(etype)].items, 0..) |*r, i| {
        if (r.listener == listener and r.callback == fun) break i;
    } else {
        return;
    };

    _ = registrations[@intFromEnum(etype)].swapRemove(index);
}
pub fn fire(event: Event, sender: ?*anyopaque) bool {
    for (registrations[@intFromEnum(event)].items) |r| {
        if (r.callback(r.listener, event, sender)) return true;
    }
    return false;
}
