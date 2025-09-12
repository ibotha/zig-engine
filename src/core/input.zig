// Leverages the event subsystem to collect input events together nicely.
const event = @import("event.zig");
const std = @import("std");

// TODO: Find a way to use comptime for event system type safety
// const default: bool = false;

// fn gen_btn_map(T: type) type {
//     const fields = @typeInfo(T).@"enum".fields;
//     comptime var ret_fields: [fields.len]std.builtin.Type.StructField = undefined;

//     for (fields, 0..) |f, i| {
//         ret_fields[i] = std.builtin.Type.StructField{
//             .name = f.name,
//             .type = bool,
//             .default_value_ptr = @ptrCast(&default),
//             .is_comptime = false,
//             .alignment = 0,
//         };
//     }
//     return @Type(.{ .@"struct" = .{
//         .fields = &ret_fields,
//         .layout = .@"packed",
//         .decls = &.{},
//         .is_tuple = false,
//     } });
// }

var button_map: [@typeInfo(event.Button).@"enum".fields.len]bool = undefined;
var just_pressed_button_map: [@typeInfo(event.Button).@"enum".fields.len]bool = undefined;
var just_released_button_map: [@typeInfo(event.Button).@"enum".fields.len]bool = undefined;

fn setButtonPressed(k: event.Button, v: bool) void {
    const i: usize = @intFromEnum(k);
    button_map[i] = v;
    if (v) {
        just_pressed_button_map[i] = true;
    } else {
        just_released_button_map[i] = true;
    }
}

/// Is the given button pressed right now
pub fn isButtonPressed(k: event.Button) bool {
    return button_map[@intFromEnum(k)];
}

/// Returns true if the button was just pressed between the last frame and this one
pub fn wasButtonPressed(k: event.Button) bool {
    return just_pressed_button_map[@intFromEnum(k)];
}

/// Returns true if the button was just released between the last frame and this one
pub fn wasButtonReleased(k: event.Button) bool {
    return just_released_button_map[@intFromEnum(k)];
}

pub fn init() !void {
    try event.listen(.button, null, onButton);
}
pub fn deinit() void {
    event.unlisten(.button, null, onButton);
}

pub fn update(delta: f64) void {
    @memset(&just_pressed_button_map, false);
    @memset(&just_released_button_map, false);
    _ = delta;
}

fn onButton(_: ?*anyopaque, ev: event.Event, _: ?*anyopaque) bool {
    setButtonPressed(ev.button.button, ev.button.pressed);
    return true;
}
