const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigvim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // TODO: TASK-002 - Link LuaJIT
    // exe.root_module.linkSystemLibrary("luajit", .{});
    // exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    // exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    // TODO: TASK-011 - Link libuv
    // exe.root_module.linkSystemLibrary("uv", .{});

    b.installArtifact(exe);
}
