const std = @import("std");
const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("libdecor-0/libdecor.h");
    @cInclude("wayland-cursor.h");
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
});

const mem = std.mem;
const Allocator = mem.Allocator;
const posix = std.posix;

const core = @import("core");
const event = core.event;
const common = @import("common.zig");
const wayland = @import("wayland");
// TODO: WTF is a wl?
const wl = wayland.client.wl;
// TODO: WTF is a xdg?
const xdg = wayland.client.xdg;

const iface = c.struct_libdecor_interface{
    .@"error" = handleError,
};

const frame_iface = c.struct_libdecor_frame_interface{
    .configure = @ptrCast(&frameConfigure),
    .close = @ptrCast(&frameClose),
    .commit = @ptrCast(&frameCommit),
    .dismiss_popup = @ptrCast(&frameDismissPopup),
};

const WaylandContext = struct {
    display: *wl.Display = undefined,
    registry: *wl.Registry = undefined,
    compositor: *wl.Compositor = undefined,
    wm_base: *xdg.WmBase = undefined,
    shm: *wl.Shm = undefined,
    cursor: *wl.Surface = undefined,
    cursor_buffer: *wl.Buffer = undefined,
    cursor_image: *c.wl_cursor_image = undefined,
    cursor_theme: ?*c.struct_wl_cursor_theme = undefined,
};

const Window = struct {
    content_width: u16 = 0,
    content_height: u16 = 0,
    floating_width: u16 = 1080,
    floating_height: u16 = 720,
    configured_width: u16 = 0,
    configured_height: u16 = 0,
    window_state: c.enum_libdecor_window_state = c.LIBDECOR_WINDOW_STATE_NONE,
    surface: *wl.Surface = undefined,
    ldecor: *c.struct_libdecor = undefined,
    frame: *c.struct_libdecor_frame = undefined,
};

fn frameConfigure(frame: ?*c.struct_libdecor_frame, config: ?*c.struct_libdecor_configuration, _: ?*anyopaque) callconv(.c) void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var window_state: c.enum_libdecor_window_state = undefined;
    var state: *c.struct_libdecor_state = undefined;

    if (!c.libdecor_configuration_get_content_size(config, frame, &width, &height)) {
        width = @intCast(window.content_width);
        height = @intCast(window.content_height);
    }

    width = if (width == 0) @intCast(window.floating_width) else width;
    height = if (height == 0) @intCast(window.floating_height) else height;

    window.configured_width = @intCast(width);
    window.configured_height = @intCast(height);

    if (!c.libdecor_configuration_get_window_state(config, &window_state))
        window_state = c.LIBDECOR_WINDOW_STATE_NONE;

    window.window_state = window_state;

    state = c.libdecor_state_new(width, height).?;
    c.libdecor_frame_commit(frame, state, config);
    c.libdecor_state_free(state);

    // store floating dimensions
    if (c.libdecor_frame_is_floating(window.frame)) {
        window.floating_width = @intCast(width);
        window.floating_height = @intCast(height);
    }
}

fn frameClose(_: ?*c.struct_libdecor_frame, _: ?*anyopaque) callconv(.c) void {
    event.fire(.closed, null);
}

fn frameCommit(_: ?*c.struct_libdecor_frame, _: ?*anyopaque) callconv(.c) void {
    window.surface.commit();
}

fn frameDismissPopup(_: ?*c.struct_libdecor_frame, _: ?*anyopaque) callconv(.c) void {
    // TODO: dismiss popups
}

const Input = struct {
    seat: *wl.Seat = undefined,
    kbd: *wl.Keyboard = undefined,
    mouse: *wl.Pointer = undefined,
    mouse_state: struct {
        entered: bool = false,
        x: i32 = 0,
        y: i32 = 0,
    } = .{},
    key_state: struct {
        entered: bool = false,
    } = .{},
};
var window = Window{};
var context = WaylandContext{};
var input = Input{};

pub fn init(opts: common.PlatformOpts) !void {
    context.display = try wl.Display.connect(null);
    context.registry = try context.display.getRegistry();
    context.registry.setListener(?*anyopaque, eventListener, null);

    if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    window.surface = try context.compositor.createSurface();
    context.cursor_theme =
        c.wl_cursor_theme_load(null, 24, @ptrCast(context.shm));
    const cursor =
        c.wl_cursor_theme_get_cursor(context.cursor_theme, "left_ptr");
    context.cursor_image = cursor.*.images[0..cursor.*.image_count][0];
    context.cursor_buffer =
        @ptrCast(c.wl_cursor_image_get_buffer(context.cursor_image));

    context.cursor = try context.compositor.createSurface();
    context.cursor.attach(context.cursor_buffer, 0, 0);
    context.cursor.commit();

    if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    window.floating_width = @intCast(opts.size_hint.x);
    window.floating_height = @intCast(opts.size_hint.y);
    window.content_width = 0;
    window.content_height = 0;
    window.ldecor = c.libdecor_new(@ptrCast(context.display), @ptrCast(@constCast(&iface))) orelse return error.LibdecorFailed;
    window.frame = c.libdecor_decorate(window.ldecor, @ptrCast(window.surface), @ptrCast(@constCast(&frame_iface)), @ptrCast(&window)) orelse return error.CouldNotDecorate;
    c.libdecor_frame_set_app_id(window.frame, @ptrCast(opts.name));
    c.libdecor_frame_set_title(window.frame, @ptrCast(opts.name));
    c.libdecor_frame_map(window.frame);

    if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

pub fn deinit() void {
    c.libdecor_frame_close(window.frame);
    context.cursor.destroy();
    window.surface.destroy();
    c.wl_cursor_theme_destroy(context.cursor_theme);
    wl.Display.disconnect(context.display);
}

pub fn poll_events() !void {
    if (c.libdecor_dispatch(window.ldecor, 0) < 0) {
        // @panic("Wayland event dispatch didn't return SUCCESS");
    }
}

pub fn get_surface() *anyopaque {
    return window.surface;
}

pub fn get_display() *anyopaque {
    return context.display;
}

pub fn content_size() struct { x: u16, y: u16 } {
    return .{ .x = window.configured_width, .y = window.configured_height };
}

fn eventListener(registry: *wl.Registry, e: wl.Registry.Event, _: ?*anyopaque) void {
    switch (e) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = (registry.bind(global.name, wl.Compositor, 1) catch return);
            } else if (mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                input.seat = (registry.bind(global.name, wl.Seat, 1) catch return);
                input.seat.setListener(?*anyopaque, handleSeatEvent, null);
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = (registry.bind(global.name, wl.Shm, 1) catch return);
            } else if (mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = (registry.bind(global.name, xdg.WmBase, 1) catch return);
                context.wm_base.setListener(?*anyopaque, handleShellPing, null);
            }
        },
        .global_remove => {},
    }
}

fn handleShellPing(shell: *xdg.WmBase, e: xdg.WmBase.Event, _: ?*anyopaque) void {
    shell.pong(e.ping.serial);
}

fn handleSeatEvent(seat: *wl.Seat, ev: wl.Seat.Event, _: ?*anyopaque) void {
    switch (ev) {
        .capabilities => |e| {
            if (e.capabilities.keyboard) {
                input.kbd = seat.getKeyboard() catch return;
                input.kbd.setListener(?*anyopaque, handleKeyboardEvent, null);
            }
            if (e.capabilities.pointer) {
                input.mouse = seat.getPointer() catch return;
                input.mouse.setListener(?*anyopaque, handleMouseEvent, null);
            }
        },
    }
}
fn handleKeyboardEvent(kbd: *wl.Keyboard, ev: wl.Keyboard.Event, _: ?*anyopaque) void {
    switch (ev) {
        .enter => |e| {
            if (e.surface == window.surface) {
                input.key_state.entered = true;
            }
        },
        .leave => |e| {
            if (e.surface == window.surface) {
                input.key_state.entered = false;
            }
        },
        .keymap => |e| {
            _ = e;
        },
        .modifiers => |e| {
            _ = e;
        },
        .key => |e| {
            if (input.key_state.entered) {
                event.fire(.{ .key = .{
                    .key = btn_tag: switch (e.key) {
                        c.KEY_0 => break :btn_tag .num_0,
                        c.KEY_1 => break :btn_tag .num_1,
                        c.KEY_2 => break :btn_tag .num_2,
                        c.KEY_3 => break :btn_tag .num_3,
                        c.KEY_4 => break :btn_tag .num_4,
                        c.KEY_5 => break :btn_tag .num_5,
                        c.KEY_6 => break :btn_tag .num_6,
                        c.KEY_7 => break :btn_tag .num_7,
                        c.KEY_8 => break :btn_tag .num_8,
                        c.KEY_9 => break :btn_tag .num_9,
                        c.KEY_A => break :btn_tag .a,
                        c.KEY_B => break :btn_tag .b,
                        c.KEY_C => break :btn_tag .c,
                        c.KEY_D => break :btn_tag .d,
                        c.KEY_E => break :btn_tag .e,
                        c.KEY_F => break :btn_tag .f,
                        c.KEY_G => break :btn_tag .g,
                        c.KEY_H => break :btn_tag .h,
                        c.KEY_I => break :btn_tag .i,
                        c.KEY_J => break :btn_tag .j,
                        c.KEY_K => break :btn_tag .k,
                        c.KEY_L => break :btn_tag .l,
                        c.KEY_M => break :btn_tag .m,
                        c.KEY_N => break :btn_tag .n,
                        c.KEY_O => break :btn_tag .o,
                        c.KEY_P => break :btn_tag .p,
                        c.KEY_Q => break :btn_tag .q,
                        c.KEY_R => break :btn_tag .r,
                        c.KEY_S => break :btn_tag .s,
                        c.KEY_T => break :btn_tag .t,
                        c.KEY_U => break :btn_tag .u,
                        c.KEY_V => break :btn_tag .v,
                        c.KEY_W => break :btn_tag .w,
                        c.KEY_X => break :btn_tag .x,
                        c.KEY_Y => break :btn_tag .y,
                        c.KEY_Z => break :btn_tag .z,
                        c.KEY_UP => break :btn_tag .up,
                        c.KEY_DOWN => break :btn_tag .down,
                        c.KEY_LEFT => break :btn_tag .left,
                        c.KEY_RIGHT => break :btn_tag .right,
                        else => .unknown,
                    },
                    .pressed = e.state == .pressed,
                } }, null);
            }
        },
    }
    _ = kbd;
}

fn handleMouseEvent(_: *wl.Pointer, ev: wl.Pointer.Event, _: ?*anyopaque) void {
    switch (ev) {
        .axis => |e| {
            switch (e.axis) {
                .vertical_scroll => {
                    event.fire(.{ .mouse_scroll = .{ .y = @intCast(e.value.toInt()), .x = 0 } }, null);
                },
                .horizontal_scroll => {
                    event.fire(.{ .mouse_scroll = .{ .x = @intCast(e.value.toInt()), .y = 0 } }, null);
                },
                _ => unreachable,
            }
        },
        .enter => |e| {
            if (e.surface == window.surface) {
                input.mouse_state.entered = true;
                input.mouse_state.x = e.surface_x.toInt();
                input.mouse_state.y = e.surface_y.toInt();
                input.mouse.setCursor(e.serial, context.cursor, @intCast(context.cursor_image.hotspot_x), @intCast(context.cursor_image.hotspot_y));
            }
        },
        .leave => |e| {
            if (e.surface == window.surface) {
                input.mouse_state.entered = false;
            }
        },
        .motion => |e| {
            if (input.mouse_state.entered) {
                event.fire(.{
                    .mouse_moved = .{
                        .x = @intCast(e.surface_x.toInt()),
                        .y = @intCast(e.surface_y.toInt()),
                    },
                }, null);
                input.mouse_state.x = e.surface_x.toInt();
                input.mouse_state.y = e.surface_y.toInt();
            }
        },
        .button => |e| {
            if (input.mouse_state.entered) {
                event.fire(.{ .mouse_button = .{
                    .button = btn_tag: switch (e.button) {
                        c.BTN_RIGHT => break :btn_tag .right,
                        c.BTN_LEFT => break :btn_tag .left,
                        c.BTN_MIDDLE => break :btn_tag .middle,
                        else => break :btn_tag .unknown,
                    },
                    .pressed = e.state == .pressed,
                } }, null);
            }
        },
    }
}

fn handleError(ldecor: ?*c.struct_libdecor, err: c.enum_libdecor_error, str: [*c]const u8) callconv(.c) void {
    std.debug.print("{s} {any} {any}", .{ str, ldecor, err });
}

/// Get absolute time in seconds
pub fn get_absolute_time() i128 {
    return std.time.nanoTimestamp();
}

pub fn sleep(s: f64) void {
    std.Thread.sleep(@intFromFloat(s * 1000000000));
}
