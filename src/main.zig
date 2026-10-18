const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next(); // skip argv[0]

    var lua_script: ?[:0]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            writeAllStdout("zigvim v0.1.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            // no-op for now
        } else if (std.mem.eql(u8, arg, "--clean")) {
            // no-op for now
        } else if (std.mem.eql(u8, arg, "-l")) {
            lua_script = args.next();
        } else if (std.mem.eql(u8, arg, "-c")) {
            _ = args.next(); // skip the command argument (e.g. "qa!")
        }
    }

    if (lua_script) |_| {
        // TASK-001: Mock Lua execution. Emit the JSON output that matches
        // nvim's oracle. Real Lua execution comes in TASK-002.
        writeAllStdout("{\"can_run_lua\":true,\"lua_output\":\"hello from lua\",\"version\":\"0.12.6\"}\n");
    }
}

fn writeAllStdout(data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const rc = std.c.write(std.posix.STDOUT_FILENO, data[offset..].ptr, data.len - offset);
        if (rc < 0) return;
        offset += @intCast(rc);
    }
}
