const std = @import("std");
const c = @import("c");
const msgpack = @import("msgpack.zig");

const Buffer = struct {
    id: u32,
    lines: std.ArrayList([]u8),
    valid: bool,
};

const BufferStore = struct {
    allocator: std.mem.Allocator,
    buffers: std.AutoHashMap(u32, Buffer),
    next_buf_id: u32,

    pub fn init(allocator: std.mem.Allocator) BufferStore {
        var store = BufferStore{
            .allocator = allocator,
            .buffers = std.AutoHashMap(u32, Buffer).init(allocator),
            .next_buf_id = 1,
        };
        // Buffer 1 always exists and starts with a single empty line.
        _ = store.create() catch unreachable;
        return store;
    }

    pub fn deinit(self: *BufferStore) void {
        var iter = self.buffers.valueIterator();
        while (iter.next()) |buf| {
            for (buf.lines.items) |line| self.allocator.free(line);
            buf.lines.deinit(self.allocator);
        }
        self.buffers.deinit();
    }

    pub fn create(self: *BufferStore) !u32 {
        const id = self.next_buf_id;
        self.next_buf_id += 1;
        var lines = std.ArrayList([]u8).initCapacity(self.allocator, 1) catch unreachable;
        try lines.append(self.allocator, try self.allocator.dupe(u8, ""));
        const buf = Buffer{
            .id = id,
            .lines = lines,
            .valid = true,
        };
        try self.buffers.put(id, buf);
        return id;
    }

    pub fn setLines(self: *BufferStore, id: u32, start: i64, end: i64, replacement: []const []const u8) !void {
        const buf = self.buffers.getPtr(id) orelse return error.InvalidBuffer;
        const len: i64 = @intCast(buf.lines.items.len);
        const s: usize = @intCast(if (start < 0) @max(0, len + start) else @min(len, start));
        var e: usize = @intCast(if (end < 0) @max(0, len + end + 1) else @min(len, end));
        if (e < s) e = s;

        var idx = e;
        while (idx > s) {
            idx -= 1;
            self.allocator.free(buf.lines.orderedRemove(idx));
        }

        var at = s;
        for (replacement) |line| {
            try buf.lines.insert(self.allocator, at, try self.allocator.dupe(u8, line));
            at += 1;
        }
    }

    pub fn getLines(self: *BufferStore, id: u32, start: i64, end: i64) ![][]u8 {
        const buf = self.buffers.getPtr(id) orelse return error.InvalidBuffer;
        const len: i64 = @intCast(buf.lines.items.len);
        const s: usize = @intCast(if (start < 0) @max(0, len + start) else @min(len, start));
        const e: usize = @intCast(if (end < 0) @max(0, len + end + 1) else @min(len, end));
        if (e <= s) return &[_][]u8{};
        return buf.lines.items[s..e];
    }

    pub fn isValid(self: *BufferStore, id: u32) bool {
        if (self.buffers.getPtr(id)) |buf| return buf.valid;
        return false;
    }

    pub fn lineCount(self: *BufferStore, id: u32) usize {
        if (self.buffers.getPtr(id)) |buf| return buf.lines.items.len;
        return 0;
    }

    pub fn delete(self: *BufferStore, id: u32) void {
        if (self.buffers.getPtr(id)) |buf| {
            for (buf.lines.items) |line| self.allocator.free(line);
            buf.lines.deinit(self.allocator);
            _ = self.buffers.remove(id);
        }
    }
};

var g_store: ?BufferStore = null;
var g_allocator: std.mem.Allocator = std.heap.page_allocator;
var g_callbacks: std.ArrayList(i32) = undefined;
var g_callbacks_init: bool = false;
var g_current_buf: u32 = 1;
var g_L: ?*c.lua_State = null;
var g_loop: ?*c.uv_loop_t = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    g_allocator = gpa;
    g_store = BufferStore.init(gpa);
    defer if (g_store) |*s| s.deinit();

    g_callbacks = std.ArrayList(i32).initCapacity(gpa, 0) catch unreachable;
    g_callbacks_init = true;
    defer {
        if (g_callbacks_init) {
            g_callbacks.deinit(gpa);
            g_callbacks_init = false;
        }
    }

    var args_iter = init.minimal.args.iterateAllocator(gpa) catch unreachable;
    defer args_iter.deinit();
    var args = std.ArrayList([]const u8).initCapacity(gpa, 0) catch unreachable;
    defer args.deinit(gpa);
    while (args_iter.next()) |arg| {
        args.append(gpa, arg) catch unreachable;
    }

    var embed_mode = false;
    var lua_script: ?[]const u8 = null;
    var lua_cmd: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "--embed")) {
            embed_mode = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            const ver = c.uv_version_string();
            const ver_slice = std.mem.span(@as([*:0]const u8, @ptrCast(ver)));
            const stdout = std.Io.File.stdout();
            try stdout.writeStreamingAll(init.io, "zigvim v0.1.0\nlibuv v");
            try stdout.writeStreamingAll(init.io, ver_slice);
            try stdout.writeStreamingAll(init.io, "\n");
            return;
        } else if (std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= args.items.len) {
                std.debug.print("Error: -l requires script path\n", .{});
                std.process.exit(1);
            }
            lua_script = args.items[i];
        } else if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.items.len) {
                std.debug.print("Error: -c requires command\n", .{});
                std.process.exit(1);
            }
            lua_cmd = args.items[i];
        }
    }

    const L = c.luaL_newstate() orelse {
        std.debug.print("Failed to create Lua state\n", .{});
        std.process.exit(1);
    };
    defer c.lua_close(L);

    c.luaL_openlibs(L);
    g_L = L;
    try registerVimGlobal(L);
    try loadPrelude(L);

    if (embed_mode) {
        try runRpcServer(init.io, L);
        return;
    }

    if (lua_script) |path| {
        const cpath = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(cpath);

        if (c.luaL_dofile(L, cpath)) {
            const err = c.lua_tolstring(L, -1, null);
            if (err != null) {
                std.debug.print("{s}\n", .{std.mem.span(err)});
            }
            std.process.exit(1);
        }

        if (lua_cmd) |cmd| {
            const is_quit = std.mem.eql(u8, cmd, "qa!") or std.mem.eql(u8, cmd, "qa") or
                std.mem.eql(u8, cmd, "q!") or std.mem.eql(u8, cmd, "q");
            if (!is_quit) {
                const ccmd = try gpa.dupeSentinel(u8, cmd, 0);
                defer gpa.free(ccmd);
                if (c.luaL_dostring(L, ccmd)) {
                    const err = c.lua_tolstring(L, -1, null);
                    if (err != null) std.debug.print("{s}\n", .{std.mem.span(err)});
                    std.process.exit(1);
                }
            }
        }

        pumpEventLoop(L);
        // Give libuv a chance to finish one-shot deferred callbacks.
        const loop = getLoop();
        _ = c.uv_run(loop, c.UV_RUN_NOWAIT);
    } else {
        std.debug.print("Usage: zigvim --embed | zigvim -l <script.lua> [-c <cmd>]\n", .{});
        std.process.exit(1);
    }
}

fn registerVimGlobal(L: *c.lua_State) !void {
    c.lua_newtable(L);

    c.lua_newtable(L);
    regApi(L);
    c.lua_setfield(L, -2, "api");

    c.lua_newtable(L);
    c.lua_pushcfunction(L, luaHas);
    c.lua_setfield(L, -2, "has");
    c.lua_setfield(L, -2, "fn");

    for ([_][]const u8{ "o", "opt", "g", "b", "w", "t", "v" }) |name| {
        c.lua_newtable(L);
        c.lua_setfield(L, -2, name.ptr);
    }

    c.lua_pushcfunction(L, luaSchedule);
    c.lua_setfield(L, -2, "schedule");
    c.lua_pushcfunction(L, luaDeferFn);
    c.lua_setfield(L, -2, "defer_fn");
    c.lua_pushcfunction(L, luaWait);
    c.lua_setfield(L, -2, "wait");
    c.lua_pushcfunction(L, luaInspect);
    c.lua_setfield(L, -2, "inspect");

    c.lua_newtable(L);
    c.lua_pushcfunction(L, luaUvNewTimer);
    c.lua_setfield(L, -2, "new_timer");
    c.lua_pushcfunction(L, luaUvVersion);
    c.lua_setfield(L, -2, "version");
    c.lua_pushcfunction(L, luaUvVersionString);
    c.lua_setfield(L, -2, "version_string");
    c.lua_pushcfunction(L, luaUvOsUname);
    c.lua_setfield(L, -2, "os_uname");
    c.lua_pushcfunction(L, luaUvCwd);
    c.lua_setfield(L, -2, "cwd");
    c.lua_pushcfunction(L, luaUvOsHomedir);
    c.lua_setfield(L, -2, "os_homedir");
    c.lua_setfield(L, -2, "uv");

    c.lua_newtable(L);
    c.lua_pushcfunction(L, luaMpackEncode);
    c.lua_setfield(L, -2, "encode");
    c.lua_pushcfunction(L, luaMpackDecode);
    c.lua_setfield(L, -2, "decode");
    c.lua_setfield(L, -2, "mpack");

    c.lua_newtable(L);
    c.lua_pushcfunction(L, luaJsonDecode);
    c.lua_setfield(L, -2, "decode");
    c.lua_setfield(L, -2, "json");

    c.lua_setglobal(L, "vim");
}

fn loadPrelude(L: *c.lua_State) !void {
    const src = @embedFile("prelude.lua");
    const z = try g_allocator.dupeSentinel(u8, src, 0);
    defer g_allocator.free(z);
    if (c.luaL_dostring(L, z.ptr)) {
        const err = c.lua_tolstring(L, -1, null);
        if (err != null) std.debug.print("prelude error: {s}\n", .{std.mem.span(err)});
        return error.PreludeFailed;
    }
}

fn regApi(L: *c.lua_State) void {
    const pairs = [_]struct { name: [*:0]const u8, f: c.lua_CFunction }{
        .{ .name = "nvim_create_buf", .f = @ptrCast(&luaCreateBuf) },
        .{ .name = "nvim_buf_is_valid", .f = @ptrCast(&luaBufIsValid) },
        .{ .name = "nvim_buf_set_lines", .f = @ptrCast(&luaBufSetLines) },
        .{ .name = "nvim_buf_get_lines", .f = @ptrCast(&luaBufGetLines) },
        .{ .name = "nvim_buf_line_count", .f = @ptrCast(&luaBufLineCount) },
        .{ .name = "nvim_buf_delete", .f = @ptrCast(&luaBufDelete) },
        .{ .name = "nvim_get_current_buf", .f = @ptrCast(&luaGetCurrentBuf) },
        .{ .name = "nvim_set_current_buf", .f = @ptrCast(&luaSetCurrentBuf) },
        .{ .name = "nvim_get_current_win", .f = @ptrCast(&luaGetCurrentWin) },
        .{ .name = "nvim_list_bufs", .f = @ptrCast(&luaListBufs) },
        .{ .name = "nvim_list_wins", .f = @ptrCast(&luaListWins) },
        .{ .name = "nvim_create_augroup", .f = @ptrCast(&luaCreateAugroup) },
        .{ .name = "nvim_create_autocmd", .f = @ptrCast(&luaCreateAutocmd) },
        .{ .name = "nvim_exec_autocmds", .f = @ptrCast(&luaExecAutocmds) },
    };
    inline for (pairs) |p| {
        c.lua_pushcfunction(L, p.f);
        c.lua_setfield(L, -2, p.name);
    }
}

fn luaHas(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const f = c.luaL_checklstring(LS, 1, null);
    if (std.mem.eql(u8, std.mem.span(f), "nvim")) c.lua_pushinteger(LS, 1) else c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaCreateBuf(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    // nvim_create_buf(listed, scratch) takes two booleans.
    _ = c.lua_toboolean(LS, 1);
    _ = c.lua_toboolean(LS, 2);
    if (g_store) |*s| {
        const id = s.create() catch {
            c.lua_pushnil(LS);
            return 1;
        };
        c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(id)));
    } else {
        c.lua_pushinteger(LS, 1);
    }
    return 1;
}

fn luaBufIsValid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    if (g_store) |*s| c.lua_pushboolean(LS, if (s.isValid(@intCast(id))) 1 else 0) else c.lua_pushboolean(LS, if (id > 0) 1 else 0);
    return 1;
}

fn luaBufSetLines(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    const start = c.luaL_checkinteger(LS, 2);
    const end = c.luaL_checkinteger(LS, 3);
    _ = c.lua_toboolean(LS, 4);
    _ = c.luaL_checktype(LS, 5, c.LUA_TTABLE);

    const n = c.lua_objlen(LS, 5);
    var repl = std.ArrayList([]const u8).initCapacity(g_allocator, n) catch {
        _ = c.luaL_error(LS, "out of memory");
        return 0;
    };
    defer repl.deinit(g_allocator);

    var idx: usize = 1;
    while (idx <= n) : (idx += 1) {
        c.lua_rawgeti(LS, 5, @intCast(idx));
        var len: usize = 0;
        const str = c.lua_tolstring(LS, -1, &len);
        if (str != null) {
            repl.append(g_allocator, str[0..len]) catch {
                c.lua_pop(LS, 1);
                _ = c.luaL_error(LS, "out of memory");
                return 0;
            };
        }
        c.lua_pop(LS, 1);
    }

    if (g_store) |*s| {
        s.setLines(@intCast(id), start, end, repl.items) catch {
            _ = c.luaL_error(LS, "invalid buffer");
            return 0;
        };
    }
    return 0;
}

fn luaBufGetLines(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    const start = c.luaL_checkinteger(LS, 2);
    const end = c.luaL_checkinteger(LS, 3);
    _ = c.lua_toboolean(LS, 4);

    c.lua_newtable(LS);
    if (g_store) |*s| {
        const lines = s.getLines(@intCast(id), start, end) catch &[_][]u8{};
        for (lines, 0..) |line, i| {
            c.lua_pushlstring(LS, line.ptr, line.len);
            c.lua_rawseti(LS, -2, @as(c_int, @intCast(i + 1)));
        }
    }
    return 1;
}

fn luaBufLineCount(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    if (g_store) |*s| c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(s.lineCount(@intCast(id))))) else c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaBufDelete(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    if (g_store) |*s| s.delete(@intCast(id));
    return 0;
}

fn luaGetCurrentBuf(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_buf)));
    return 1;
}

fn luaSetCurrentBuf(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    if (g_store) |*s| {
        if (s.isValid(@intCast(id))) g_current_buf = @intCast(id);
    }
    return 0;
}

fn luaGetCurrentWin(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, 1000);
    return 1;
}

fn luaListBufs(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_newtable(LS);
    if (g_store) |*s| {
        var count: c_int = 0;
        var iter = s.buffers.keyIterator();
        while (iter.next()) |id| {
            if (s.isValid(id.*)) {
                count += 1;
                c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(id.*)));
                c.lua_rawseti(LS, -2, count);
            }
        }
    }
    return 1;
}

fn luaListWins(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_newtable(LS);
    c.lua_pushinteger(LS, 1000);
    c.lua_rawseti(LS, -2, 1);
    return 1;
}

fn luaCreateAugroup(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checklstring(LS, 1, null);
    c.lua_pushinteger(LS, 1);
    return 1;
}

fn luaCreateAutocmd(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, 1);
    return 1;
}

fn luaExecAutocmds(L: ?*c.lua_State) callconv(.c) c_int {
    _ = L;
    return 0;
}

fn luaSchedule(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (c.lua_gettop(LS) >= 1 and c.lua_isfunction(LS, 1)) {
        c.lua_pushvalue(LS, 1);
        const ref = c.luaL_ref(LS, c.LUA_REGISTRYINDEX);
        if (g_callbacks_init) g_callbacks.append(g_allocator, ref) catch c.luaL_unref(LS, c.LUA_REGISTRYINDEX, ref);
    }
    return 0;
}

fn getLoop() *c.uv_loop_t {
    if (g_loop == null) g_loop = c.uv_default_loop();
    return g_loop.?;
}

fn luaDeferFn(L: ?*c.lua_State) callconv(.c) c_int {
    _ = L;
    return 0;
}

fn luaWait(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const timeout: u64 = @intFromFloat(@max(0.0, c.luaL_checknumber(LS, 1)));
    const has_cond = c.lua_gettop(LS) >= 2 and c.lua_isfunction(LS, 2);
    var cond_ref: c_int = c.LUA_NOREF;
    if (has_cond) {
        c.lua_pushvalue(LS, 2);
        cond_ref = c.luaL_ref(LS, c.LUA_REGISTRYINDEX);
    }
    defer if (cond_ref != c.LUA_NOREF) c.luaL_unref(LS, c.LUA_REGISTRYINDEX, cond_ref);

    const loop = getLoop();
    const deadline = c.uv_hrtime() + timeout * 1_000_000;

    while (true) {
        pumpEventLoop(LS);

        if (has_cond) {
            c.lua_rawgeti(LS, c.LUA_REGISTRYINDEX, cond_ref);
            if (c.lua_pcall(LS, 0, 1, 0) == 0) {
                const truthy = c.lua_toboolean(LS, -1) != 0;
                c.lua_pop(LS, 1);
                if (truthy) {
                    c.lua_pushboolean(LS, 1);
                    return 1;
                }
            } else {
                c.lua_pop(LS, 1);
            }
        }

        if (timeout == 0 or c.uv_hrtime() >= deadline) break;
        _ = c.uv_run(loop, c.UV_RUN_NOWAIT);
        c.uv_sleep(1);
    }

    if (has_cond) {
        // Neovim returns `false, -1` when the condition times out.
        c.lua_pushboolean(LS, 0);
        c.lua_pushinteger(LS, -1);
        return 2;
    }
    c.lua_pushboolean(LS, 1);
    return 1;
}

const TimerBox = struct {
    handle: c.uv_timer_t = undefined,
    ref: c_int = c.LUA_NOREF,
};

fn boxFromSelf(L: *c.lua_State) ?*TimerBox {
    _ = c.lua_getfield(L, 1, "__handle");
    const ptr = c.lua_touserdata(L, -1);
    c.lua_pop(L, 1);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

fn luaUvNewTimer(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = std.heap.page_allocator.create(TimerBox) catch {
        c.lua_pushnil(LS);
        return 1;
    };
    box.* = .{};
    box.handle.data = box;
    if (c.uv_timer_init(getLoop(), &box.handle) != 0) {
        std.heap.page_allocator.destroy(box);
        c.lua_pushnil(LS);
        return 1;
    }

    c.lua_newtable(LS);
    c.lua_pushlightuserdata(LS, box);
    c.lua_setfield(LS, -2, "__handle");

    c.lua_newtable(LS);
    c.lua_pushcfunction(LS, luaTimerStart);
    c.lua_setfield(LS, -2, "start");
    c.lua_pushcfunction(LS, luaTimerStop);
    c.lua_setfield(LS, -2, "stop");
    c.lua_pushcfunction(LS, luaTimerClose);
    c.lua_setfield(LS, -2, "close");
    // Make method lookup work: metatable.__index = metatable.
    c.lua_pushvalue(LS, -1);
    c.lua_setfield(LS, -2, "__index");
    _ = c.lua_setmetatable(LS, -2);
    return 1;
}

fn luaTimerStart(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = boxFromSelf(LS) orelse return 0;
    const timeout = c.luaL_checkinteger(LS, 2);
    const repeat = c.luaL_optinteger(LS, 3, 0);
    if (!c.lua_isfunction(LS, 4)) {
        _ = c.luaL_error(LS, "timer callback required");
        return 0;
    }

    if (box.ref != c.LUA_NOREF) c.luaL_unref(LS, c.LUA_REGISTRYINDEX, box.ref);
    c.lua_pushvalue(LS, 4);
    box.ref = c.luaL_ref(LS, c.LUA_REGISTRYINDEX);

    _ = c.uv_timer_start(&box.handle, timerCallback, @intCast(@max(0, timeout)), @intCast(@max(0, repeat)));
    return 0;
}

fn luaTimerStop(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (boxFromSelf(LS)) |box| _ = c.uv_timer_stop(&box.handle);
    return 0;
}

fn luaTimerClose(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (boxFromSelf(LS)) |box| {
        _ = c.uv_timer_stop(&box.handle);
        c.uv_close(@ptrCast(&box.handle), timerCloseCallback);
    }
    return 0;
}

fn timerCallback(handle: [*c]c.uv_timer_t) callconv(.c) void {
    const box: *TimerBox = @ptrCast(@alignCast(handle[0].data.?));
    const L = g_L orelse return;
    if (box.ref == c.LUA_NOREF) return;
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, box.ref);
    if (c.lua_pcall(L, 0, 0, 0) != 0) c.lua_pop(L, 1);
}

fn timerCloseCallback(handle: [*c]c.uv_handle_t) callconv(.c) void {
    const box: *TimerBox = @ptrCast(@alignCast(handle[0].data.?));
    if (g_L) |L| {
        if (box.ref != c.LUA_NOREF) c.luaL_unref(L, c.LUA_REGISTRYINDEX, box.ref);
    }
    std.heap.page_allocator.destroy(box);
}

fn luaUvVersion(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(c.uv_version())));
    return 1;
}

fn luaUvVersionString(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushstring(LS, c.uv_version_string());
    return 1;
}

fn luaUvOsUname(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var u: c.uv_utsname_t = undefined;
    if (c.uv_os_uname(&u) != 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    c.lua_newtable(LS);
    pushField(LS, "sysname", &u.sysname);
    pushField(LS, "release", &u.release);
    pushField(LS, "version", &u.version);
    pushField(LS, "machine", &u.machine);
    return 1;
}

fn pushField(L: *c.lua_State, name: [*:0]const u8, buf: *const [256]u8) void {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    c.lua_pushlstring(L, buf, len);
    c.lua_setfield(L, -2, name);
}

fn luaUvCwd(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var buf: [4096]u8 = undefined;
    var size: usize = buf.len;
    if (c.uv_cwd(&buf, &size) != 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    c.lua_pushlstring(LS, &buf, len);
    return 1;
}

fn luaUvOsHomedir(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var buf: [4096]u8 = undefined;
    var size: usize = buf.len;
    if (c.uv_os_homedir(&buf, &size) != 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    c.lua_pushlstring(LS, &buf, len);
    return 1;
}

fn luaMpackEncode(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const allocator = std.heap.page_allocator;
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer buf.deinit(allocator);
    luaValueToMpack(LS, 1, &buf) catch {
        c.lua_pushstring(LS, "");
        return 1;
    };
    c.lua_pushlstring(LS, buf.items.ptr, buf.items.len);
    return 1;
}

fn luaMpackDecode(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var len: usize = 0;
    const data = c.luaL_checklstring(LS, 1, &len);
    if (data == null or len == 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    const allocator = std.heap.page_allocator;
    const decoded = msgpack.decode(allocator, data[0..len]) catch {
        c.lua_pushnil(LS);
        return 1;
    };
    mpackValueToLua(LS, decoded);
    return 1;
}

fn luaInspect(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (c.lua_gettop(LS) >= 1) {
        var len: usize = 0;
        const str = c.lua_tolstring(LS, 1, &len);
        if (str != null) c.lua_pushlstring(LS, str, len) else c.lua_pushstring(LS, "nil");
    } else c.lua_pushstring(LS, "nil");
    return 1;
}

fn luaJsonDecode(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const s = c.luaL_checklstring(LS, 1, null);
    if (s == null) {
        c.lua_pushnil(LS);
        return 1;
    }
    _ = std.mem.span(s);
    c.lua_pushnil(LS);
    return 1;
}

fn luaValueToMpack(L: *c.lua_State, idx: c_int, buf: *std.ArrayList(u8)) !void {
    const a = std.heap.page_allocator;
    const abs: c_int = if (idx < 0) c.lua_gettop(L) + idx + 1 else idx;
    switch (c.lua_type(L, abs)) {
        c.LUA_TNIL => try msgpack.encodeNil(a, buf),
        c.LUA_TBOOLEAN => try msgpack.encodeBool(a, buf, c.lua_toboolean(L, abs) != 0),
        c.LUA_TNUMBER => {
            const v = c.lua_tonumber(L, abs);
            if (v == @trunc(v) and v >= -9223372036854775808.0 and v < 9223372036854775808.0) {
                try msgpack.encodeInt(a, buf, @intFromFloat(v));
            } else {
                try msgpack.encodeFloat(a, buf, v);
            }
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const str = c.lua_tolstring(L, abs, &len);
            if (str != null) try msgpack.encodeString(a, buf, str[0..len]);
        },
        c.LUA_TTABLE => {
            const len = c.lua_objlen(L, abs);
            if (len > 0) {
                try msgpack.encodeArrayStart(a, buf, @intCast(len));
                var i: c_int = 1;
                while (i <= @as(c_int, @intCast(len))) : (i += 1) {
                    c.lua_rawgeti(L, abs, i);
                    try luaValueToMpack(L, -1, buf);
                    c.lua_pop(L, 1);
                }
            } else {
                var count: usize = 0;
                c.lua_pushnil(L);
                while (c.lua_next(L, abs) != 0) : (c.lua_pop(L, 1)) count += 1;
                try msgpack.encodeMapStart(a, buf, @intCast(count));
                c.lua_pushnil(L);
                while (c.lua_next(L, abs) != 0) : (c.lua_pop(L, 1)) {
                    try luaValueToMpack(L, -2, buf);
                    try luaValueToMpack(L, -1, buf);
                }
            }
        },
        else => try msgpack.encodeNil(a, buf),
    }
}

fn mpackValueToLua(L: *c.lua_State, v: msgpack.Value) void {
    switch (v) {
        .nil => c.lua_pushnil(L),
        .boolean => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .int => |i| c.lua_pushinteger(L, i),
        .uint => |u| c.lua_pushinteger(L, @as(c.lua_Integer, @intCast(u))),
        .float => |f| c.lua_pushnumber(L, f),
        .string => |s| c.lua_pushlstring(L, s.ptr, s.len),
        .array => |arr| {
            c.lua_newtable(L);
            for (arr, 0..) |item, i| {
                mpackValueToLua(L, item);
                c.lua_rawseti(L, -2, @as(c_int, @intCast(i + 1)));
            }
        },
        .map => |entries| {
            c.lua_newtable(L);
            for (entries) |e| {
                mpackValueToLua(L, e.key);
                mpackValueToLua(L, e.value);
                c.lua_settable(L, -3);
            }
        },
        .binary => |b| c.lua_pushlstring(L, b.ptr, b.len),
        .ext => c.lua_pushnil(L),
    }
}

fn pumpEventLoop(L: *c.lua_State) void {
    if (!g_callbacks_init) return;
    while (g_callbacks.items.len > 0) {
        const ref = g_callbacks.orderedRemove(0);
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
        if (c.lua_pcall(L, 0, 0, 0) != 0) c.lua_pop(L, 1);
    }
}

// ---------------------------------------------------------------- RPC server
// Minimal msgpack-RPC server used by `zigvim --embed`.

fn appendApiInfo(out: *std.ArrayList(u8), msgid: u32) void {
    const a = g_allocator;
    msgpack.encodeArrayStart(a, out, 4) catch return;
    msgpack.encodeInt(a, out, 1) catch return;
    msgpack.encodeInt(a, out, msgid) catch return;
    msgpack.encodeNil(a, out) catch return;

    msgpack.encodeArrayStart(a, out, 2) catch return;
    msgpack.encodeInt(a, out, 1) catch return;
    msgpack.encodeMapStart(a, out, 3) catch return;

    msgpack.encodeString(a, out, "version") catch return;
    msgpack.encodeMapStart(a, out, 3) catch return;
    msgpack.encodeString(a, out, "major") catch return;
    msgpack.encodeInt(a, out, 0) catch return;
    msgpack.encodeString(a, out, "minor") catch return;
    msgpack.encodeInt(a, out, 1) catch return;
    msgpack.encodeString(a, out, "patch") catch return;
    msgpack.encodeInt(a, out, 0) catch return;

    msgpack.encodeString(a, out, "functions") catch return;
    msgpack.encodeArrayStart(a, out, 0) catch return;

    msgpack.encodeString(a, out, "types") catch return;
    msgpack.encodeMapStart(a, out, 0) catch return;
}

fn appendEval(L: *c.lua_State, out: *std.ArrayList(u8), expr: []const u8) bool {
    const code = std.fmt.allocPrint(g_allocator, "return ({s})", .{expr}) catch return false;
    defer g_allocator.free(code);
    const z = g_allocator.dupeSentinel(u8, code, 0) catch return false;
    defer g_allocator.free(z);

    if (c.luaL_loadstring(L, z.ptr) != 0) {
        c.lua_pop(L, 1);
        return false;
    }
    if (c.lua_pcall(L, 0, 1, 0) != 0) {
        c.lua_pop(L, 1);
        return false;
    }
    luaValueToMpack(L, -1, out) catch {
        c.lua_pop(L, 1);
        return false;
    };
    c.lua_pop(L, 1);
    return true;
}

fn appendError(out: *std.ArrayList(u8), msgid: u32, message: []const u8) void {
    const a = g_allocator;
    msgpack.encodeArrayStart(a, out, 4) catch return;
    msgpack.encodeInt(a, out, 1) catch return;
    msgpack.encodeInt(a, out, msgid) catch return;
    msgpack.encodeArrayStart(a, out, 2) catch return;
    msgpack.encodeInt(a, out, 0) catch return;
    msgpack.encodeString(a, out, message) catch return;
    msgpack.encodeNil(a, out) catch return;
}

fn handleRpcMessage(L: *c.lua_State, message: msgpack.Value) ?[]u8 {
    if (message != .array) return null;
    const arr = message.array;
    if (arr.len < 1) return null;

    const kind: u64 = switch (arr[0]) {
        .uint => |u| u,
        .int => |i| if (i >= 0) @intCast(i) else return null,
        else => return null,
    };
    // Responses from the client are ignored.
    if (kind == 1) return null;
    // Notifications are dispatched without a reply.
    if (kind != 0) return null;
    if (arr.len < 4) return null;

    const msgid: u32 = switch (arr[1]) {
        .uint => |u| @intCast(u),
        .int => |i| if (i >= 0) @intCast(i) else return null,
        else => return null,
    };
    const method = switch (arr[2]) {
        .string => |s| s,
        else => return null,
    };
    const params = switch (arr[3]) {
        .array => |a| a,
        else => return null,
    };

    var out = std.ArrayList(u8).initCapacity(g_allocator, 128) catch return null;

    if (std.mem.eql(u8, method, "nvim_get_api_info")) {
        appendApiInfo(&out, msgid);
        return out.toOwnedSlice(g_allocator) catch null;
    }

    if (std.mem.eql(u8, method, "nvim_eval") and params.len >= 1 and params[0] == .string) {
        var result = std.ArrayList(u8).initCapacity(g_allocator, 64) catch return null;
        if (!appendEval(L, &result, params[0].string)) {
            result.deinit(g_allocator);
            appendError(&out, msgid, "Error evaluating expression");
            return out.toOwnedSlice(g_allocator) catch null;
        }
        const a = g_allocator;
        msgpack.encodeArrayStart(a, &out, 4) catch {};
        msgpack.encodeInt(a, &out, 1) catch {};
        msgpack.encodeInt(a, &out, msgid) catch {};
        msgpack.encodeNil(a, &out) catch {};
        out.appendSlice(a, result.items) catch {};
        result.deinit(g_allocator);
        return out.toOwnedSlice(g_allocator) catch null;
    }

    if (std.mem.eql(u8, method, "nvim_command") or std.mem.eql(u8, method, "nvim_call_function") or std.mem.eql(u8, method, "nvim_exec_lua")) {
        const a = g_allocator;
        msgpack.encodeArrayStart(a, &out, 4) catch {};
        msgpack.encodeInt(a, &out, 1) catch {};
        msgpack.encodeInt(a, &out, msgid) catch {};
        msgpack.encodeNil(a, &out) catch {};
        msgpack.encodeNil(a, &out) catch {};
        return out.toOwnedSlice(g_allocator) catch null;
    }

    appendError(&out, msgid, "Invalid method");
    return out.toOwnedSlice(g_allocator) catch null;
}

fn runRpcServer(io: std.Io, L: *c.lua_State) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var read_buf: [8192]u8 = undefined;
    var pending = std.ArrayList(u8).initCapacity(g_allocator, 0) catch return;
    defer pending.deinit(g_allocator);

    while (true) {
        const n = stdin.readStreaming(io, &.{&read_buf}) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (n == 0) return;
        try pending.appendSlice(g_allocator, read_buf[0..n]);

        while (pending.items.len > 0) {
            const decoded = msgpack.decodeSlice(std.heap.page_allocator, pending.items) catch break;
            if (handleRpcMessage(L, decoded.value)) |response| {
                defer g_allocator.free(response);
                try stdout.writeStreamingAll(io, response);
            }
            const consumed = decoded.consumed;
            if (consumed == 0 or consumed > pending.items.len) break;
            std.mem.copyForwards(u8, pending.items[0..], pending.items[consumed..]);
            pending.items.len -= consumed;
        }
    }
}
