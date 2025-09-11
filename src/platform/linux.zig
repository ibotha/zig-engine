const std = @import("std");
const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("libdecor-0/libdecor.h");
    @cInclude("wayland-cursor.h");
});
const mem = std.mem;
const Allocator = mem.Allocator;
const posix = std.posix;

const core = @import("core");
const common = @import("common.zig");
const wayland = @import("wayland");
const render_backend = @import("renderer_backend");
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
    want_close: bool = false,
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
    window.want_close = true;
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
};
var window = Window{};
var context = WaylandContext{};
var input = Input{};

pub fn init(allocator: Allocator, opts: common.PlatformOpts) !void {
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

    window.want_close = false;

    if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    try render_backend.init(allocator, .{
        .name = opts.name,
        .start_width = opts.size_hint.x,
        .start_height = opts.size_hint.y,
    });
}

pub fn deinit() void {
    render_backend.deinit();
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
    try render_backend.startFrame();
    render_backend.clear(.{
        @as(f32, @floatFromInt(input.mouse_state.x)) / @as(f32, @floatFromInt(window.configured_width)),
        @as(f32, @floatFromInt(input.mouse_state.y)) / @as(f32, @floatFromInt(window.configured_height)),
        0,
        1,
    });
    try render_backend.endFrame();
}

pub fn want_close() bool {
    return window.want_close;
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

fn handleShellPing(shell: *xdg.WmBase, event: xdg.WmBase.Event, _: ?*anyopaque) void {
    shell.pong(event.ping.serial);
}

fn handleSeatEvent(seat: *wl.Seat, event: wl.Seat.Event, _: ?*anyopaque) void {
    switch (event) {
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
fn handleKeyboardEvent(kbd: *wl.Keyboard, event: wl.Keyboard.Event, _: ?*anyopaque) void {
    _ = kbd;
    _ = event;
}

fn handleMouseEvent(_: *wl.Pointer, event: wl.Pointer.Event, _: ?*anyopaque) void {
    switch (event) {
        .axis => |e| {
            switch (e.axis) {
                .vertical_scroll => {},
                .horizontal_scroll => {},
                _ => {},
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
            input.mouse_state.x = e.surface_x.toInt();
            input.mouse_state.y = e.surface_y.toInt();
        },
        .button => |e| {
            if (input.mouse_state.entered) {
                std.debug.print("Button pressed {any}\n", .{e});
                if (e.button == c.BTN_RIGHT and e.state == .pressed) c.libdecor_frame_show_window_menu(
                    window.frame,
                    @ptrCast(input.seat),
                    e.serial,
                    input.mouse_state.x,
                    input.mouse_state.y,
                );
            }
            // if (e.button == c.BTN_RIGHT and e.state == .pressed) context.xdg_toplevel.showWindowMenu(context.seat, e.serial, context.mouse_state.x, context.mouse_state.y);
        },
    }
}

fn handleError(ldecor: ?*c.struct_libdecor, err: c.enum_libdecor_error, str: [*c]const u8) callconv(.c) void {
    std.debug.print("{s} {any} {any}", .{ str, ldecor, err });
}
