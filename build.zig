const std = @import("std");

const cimgui = @import("cimgui_zig");
const Platform = cimgui.Platform;
const Renderer = cimgui.Renderer;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var exe: *std.Build.Step.Compile = undefined;
    var cimgui_dep: *std.Build.Dependency = undefined;
    const logging = b.option(bool, "toolbox-logging", "toolbox logging") orelse false;

    const zlm = b.dependency("zlm", .{
        .target = target,
        .optimize = optimize,
    }).module("zlm");

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    exe = b.addExecutable(.{
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
                .{ .name = "zlm", .module = zlm },
                .{ .name = "vulkan", .module = vulkan },
            },
        }),
    });

    exe.addCSourceFiles(.{
        .files = &.{"external/vk_mem_alloc/src.cpp"},
        .flags = &.{
            "-std=c++17",
        },
    });

    exe.addIncludePath(b.path("external/include"));

    cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = .GLFW,
        .renderer = .Vulkan,
        .@"toolbox-logging" = logging,
    });

    exe.linkLibrary(cimgui_dep.artifact("cimgui"));

    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const vert_spv = vert_cmd.addOutputFileArg("vert.spv");
    vert_cmd.addFileArg(b.path("src/shaders/triangle.vert"));
    exe.root_module.addAnonymousImport("vertex_shader", .{
        .root_source_file = vert_spv,
    });

    const frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const frag_spv = frag_cmd.addOutputFileArg("frag.spv");
    frag_cmd.addFileArg(b.path("src/shaders/triangle.frag"));
    exe.root_module.addAnonymousImport("fragment_shader", .{
        .root_source_file = frag_spv,
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
