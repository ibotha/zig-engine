const std = @import("std");

const cimgui = @import("cimgui_zig");
const Platform = cimgui.Platform;
const Renderer = cimgui.Renderer;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // var exe: *std.Build.Step.Compile = undefined;
    // var cimgui_dep: *std.Build.Dependency = undefined;
    // const logging = b.option(bool, "toolbox-logging", "toolbox logging") orelse false;

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    // exe = b.addExecutable(.{
    //     .name = "test",
    //     .root_module = std.Build.Module.create(b, .{
    //         .root_source_file = .{
    //             .cwd_relative = try b.build_root.join(b.allocator, &.{
    //                 "src",
    //                 "main.zig",
    //             }),
    //         },
    //         .target = target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "zlm", .module = zlm },
    //             .{ .name = "vulkan", .module = vulkan },
    //         },
    //     }),
    // });

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = .GLFW,
        .renderer = .Vulkan,
        .@"toolbox-logging" = false,
    });

    // const vert_cmd = b.addSystemCommand(&.{
    //     "glslc",
    //     "--target-env=vulkan1.2",
    //     "-o",
    // });
    // const vert_spv = vert_cmd.addOutputFileArg("vert.spv");
    // vert_cmd.addFileArg(b.path("src/shaders/triangle.vert"));
    // exe.root_module.addAnonymousImport("vertex_shader", .{
    //     .root_source_file = vert_spv,
    // });

    // const frag_cmd = b.addSystemCommand(&.{
    //     "glslc",
    //     "--target-env=vulkan1.2",
    //     "-o",
    // });
    // const frag_spv = frag_cmd.addOutputFileArg("frag.spv");
    // frag_cmd.addFileArg(b.path("src/shaders/triangle.frag"));
    // exe.root_module.addAnonymousImport("fragment_shader", .{
    //     .root_source_file = frag_spv,
    // });

    // b.installArtifact(exe);
    // const run_step = b.step("run", "Run the app");

    // const run_cmd = b.addRunArtifact(exe);
    // run_step.dependOn(&run_cmd.step);

    // run_cmd.step.dependOn(b.getInstallStep());

    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    // const platform = create_platform(b, target, optimize);
    // const core = b.addModule("core", .{
    //     .optimize = optimize,
    //     .target = target,
    //     .root_source_file = b.path("src/core/root.zig"),
    //     .imports = &.{
    //         .{ .name = "platform", .module = platform },
    //     },
    // });

    const zlm = b.dependency("zlm", .{
        .target = target,
        .optimize = optimize,
    }).module("zlm");

    const core = b.addModule("core", .{
        .optimize = optimize,
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zlm", .module = zlm },
        },
        .root_source_file = b.path("src/core/root.zig"),
    });

    const renderer_backend = b.addModule("renderer_backend", .{
        .optimize = optimize,
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "vulkan", .module = vulkan },
        },
        .root_source_file = b.path("src/platform/renderer_backend/vulkan.zig"),
    });

    const platform = b.addModule("platform", .{
        .optimize = optimize,
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "renderer_backend", .module = renderer_backend },
        },
        .root_source_file = b.path("src/platform/linux.zig"),
    });

    try linkWayland(b, platform);

    core.addImport("platform", platform);
    renderer_backend.addImport("platform", platform);

    const test_bed = b.addExecutable(.{
        .name = "test",
        .root_module = std.Build.Module.create(b, .{
            .root_source_file = .{
                .cwd_relative = try b.build_root.join(b.allocator, &.{
                    "src",
                    "main.zig",
                }),
            },
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platform", .module = platform },
                .{ .name = "core", .module = core },
            },
        }),
    });

    test_bed.linkLibrary(cimgui_dep.artifact("cimgui"));
    renderer_backend.linkLibrary(cimgui_dep.artifact("cimgui"));
    b.installArtifact(test_bed);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(test_bed);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

const Scanner = @import("wayland").Scanner;

pub fn linkWayland(b: *std.Build, m: *std.Build.Module) !void {
    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    // scanner.addCustomProtocol(b.path("protocol/private_foobar.xml"));

    // Pass the maximum version implemented by your wayland server or client.
    // Requests, events, enums, etc. from newer versions will not be generated,
    // ensuring forwards compatibility with newer protocol xml.
    // This will also generate code for interfaces created using the provided
    // global interface, in this example wl_keyboard, wl_pointer, xdg_surface,
    // xdg_toplevel, etc. would be generated as well.
    scanner.generate("wl_compositor", 2);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 1);
    scanner.generate("xdg_wm_base", 1);
    // scanner.generate("private_foobar_manager", 1);

    m.linkSystemLibrary("wayland-client", .{});
    m.linkSystemLibrary("wayland-cursor", .{});
    m.linkSystemLibrary("decor-0", .{});
    m.addImport("wayland", wayland);
}
