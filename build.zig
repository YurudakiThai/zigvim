const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TASK-002: Translate C headers for LuaJIT bindings
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lua_bindings.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    translate_c.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });

    const exe = b.addExecutable(.{
        .name = "zigvim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "c",
                    .module = translate_c.createModule(),
                },
            },
        }),
    });

    // TASK-002: Link LuaJIT
    exe.root_module.linkSystemLibrary("luajit", .{});
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    // TODO: TASK-011 - Link libuv
    // exe.root_module.linkSystemLibrary("uv", .{});

    b.installArtifact(exe);
}
