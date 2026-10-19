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

    // Add include paths for LuaJIT and libuv (platform-specific)
    const os_tag = target.result.os.tag;
    if (os_tag == .macos) {
        // Try Homebrew paths (Apple Silicon and Intel)
        translate_c.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/luajit-2.1" });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/local/include/luajit-2.1" });
        translate_c.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    } else if (os_tag == .linux) {
        // Standard Linux paths
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/local/include/luajit-2.1" });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/include" });
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    }
    // Windows: Will need to add path when libuv/luajit are installed via vcpkg or similar

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

    // TASK-002: Link LuaJIT (cross-platform)
    exe.root_module.linkSystemLibrary("luajit", .{});
    
    // Add library paths for LuaJIT
    if (os_tag == .macos) {
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    }

    // TASK-INFRA-001: Link libuv (cross-platform)
    exe.root_module.linkSystemLibrary("uv", .{});

    // Link libc (required for C interop)
    exe.root_module.link_libc = true;

    b.installArtifact(exe);
}
