const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const msgpack = @import("msgpack.zig");

const Buffer = struct {
    id: u32,
    lines: std.ArrayList([]u8),
    name: []u8,
    /// Name as supplied by the user (used by expand('%')), while `name` is
    /// the canonical absolute path reported by nvim_buf_get_name().
    short_name: []u8,
    modified: bool,
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
            self.allocator.free(buf.name);
            self.allocator.free(buf.short_name);
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
            .name = try self.allocator.dupe(u8, ""),
            .short_name = try self.allocator.dupe(u8, ""),
            .modified = false,
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
        buf.modified = true;
    }

    pub fn getModified(self: *BufferStore, id: u32) bool {
        if (self.buffers.getPtr(id)) |buf| return buf.modified;
        return false;
    }

    pub fn setModified(self: *BufferStore, id: u32, value: bool) void {
        if (self.buffers.getPtr(id)) |buf| buf.modified = value;
    }

    pub fn getName(self: *BufferStore, id: u32) []const u8 {
        if (self.buffers.getPtr(id)) |buf| return buf.name;
        return "";
    }

    pub fn setName(self: *BufferStore, id: u32, name: []const u8) !void {
        const buf = self.buffers.getPtr(id) orelse return error.InvalidBuffer;
        const copy = try self.absoluteName(name);
        const short = try self.allocator.dupe(u8, name);
        self.allocator.free(buf.name);
        self.allocator.free(buf.short_name);
        buf.name = copy;
        buf.short_name = short;
    }

    pub fn getShortName(self: *BufferStore, id: u32) []const u8 {
        if (self.buffers.getPtr(id)) |buf| return buf.short_name;
        return "";
    }

    /// Resolve a buffer name the way Neovim does for nvim_buf_get_name():
    /// make it absolute and canonicalise existing path components (macOS
    /// resolves /tmp to /private/tmp). The name as typed is kept separately
    /// and exposed through vim.fn.expand('%').
    pub fn absoluteName(self: *BufferStore, name: []const u8) ![]u8 {
        if (name.len == 0) return self.allocator.dupe(u8, "");
        const full = if (name[0] == '/')
            try self.allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ g_cwd, name });
        defer self.allocator.free(full);

        if (g_io) |io| {
            if (std.Io.Dir.cwd().realPathFileAlloc(io, full, self.allocator)) |real| {
                defer self.allocator.free(real);
                return self.allocator.dupe(u8, real);
            } else |_| {}

            if (std.fs.path.dirname(full)) |dir| {
                if (std.Io.Dir.cwd().realPathFileAlloc(io, dir, self.allocator)) |real_dir| {
                    defer self.allocator.free(real_dir);
                    return std.fs.path.join(self.allocator, &.{ real_dir, std.fs.path.basename(full) });
                } else |_| {}
            }
        }
        return std.fs.path.resolveAlloc(self.allocator, &.{full});
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
            self.allocator.free(buf.name);
            self.allocator.free(buf.short_name);
            _ = self.buffers.remove(id);
        }
    }
};

var g_store: ?BufferStore = null;
var g_allocator: std.mem.Allocator = std.heap.page_allocator;
var g_callbacks: std.ArrayList(i32) = undefined;
var g_callbacks_init: bool = false;
var g_current_buf: u32 = 1;
var g_current_win: u32 = 1000;
var g_current_tab: u32 = 1;
var g_win_buf: u32 = 1;
var g_cursor_row: i64 = 1;
var g_cursor_col: i64 = 0;
var g_cwd_buf: [4096]u8 = undefined;
var g_cwd: []const u8 = ".";
var g_io: ?std.Io = null;
var g_L: ?*c.lua_State = null;
var g_loop: ?*c.uv_loop_t = null;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    g_allocator = gpa;
    g_io = init.io;
    initCwd();
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
    var cmds = std.ArrayList([]const u8).initCapacity(gpa, 0) catch unreachable;
    defer cmds.deinit(gpa);
    var pre_cmds = std.ArrayList([]const u8).initCapacity(gpa, 0) catch unreachable;
    defer pre_cmds.deinit(gpa);
    var file_arg: ?[]const u8 = null;
    var clean = false;
    var headless = false;
    var init_file: ?[]const u8 = null;

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
            try cmds.append(gpa, args.items[i]);
        } else if (std.mem.eql(u8, arg, "--cmd")) {
            i += 1;
            if (i >= args.items.len) {
                std.debug.print("Error: --cmd requires command\n", .{});
                std.process.exit(1);
            }
            try pre_cmds.append(gpa, args.items[i]);
        } else if (std.mem.eql(u8, arg, "--clean")) {
            clean = true;
        } else if (std.mem.eql(u8, arg, "--headless") or std.mem.eql(u8, arg, "-es")) {
            // Never start the terminal UI (Neovim CLI compatibility).
            headless = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.items.len) {
                std.debug.print("Error: -u requires a vimrc path or NONE\n", .{});
                std.process.exit(1);
            }
            if (std.mem.eql(u8, args.items[i], "NONE")) {
                clean = true;
            } else {
                init_file = args.items[i];
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i < args.items.len and file_arg == null) file_arg = args.items[i];
            break;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else if (file_arg == null) {
            file_arg = arg;
        }
    }

    const L = c.luaL_newstate() orelse {
        std.debug.print("Failed to create Lua state\n", .{});
        std.process.exit(1);
    };
    defer c.lua_close(L);

    c.luaL_openlibs(L);
    g_L = L;
    registerEmbeddedModules(L);
    try registerVimGlobal(L);
    registerLpeg(L);
    try loadPrelude(L);
    try loadTui(L);

    // --cmd runs before any config is loaded (Neovim CLI semantics).
    for (pre_cmds.items) |cmd| _ = execVimCommand(L, cmd);

    if (embed_mode) {
        try runRpcServer(init.io, L);
        return;
    }

    if (lua_script) |path| {
        // `nvim --clean -l script.lua` still runs the startup defaults and
        // runtime plugins (but not the user config); plain `-l` runs neither.
        if (clean) _ = startupEditor(L, null, true);

        const cpath = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(cpath);

        if (c.luaL_dofile(L, cpath)) {
            const err = c.lua_tolstring(L, -1, null);
            if (err != null) {
                std.debug.print("{s}\n", .{std.mem.span(err)});
            }
            std.process.exit(1);
        }
    } else if (file_arg != null or cmds.items.len > 0 or pre_cmds.items.len > 0) {
        // Editor mode: load configuration, open the requested file, then run
        // the -c commands in order (Neovim CLI semantics).
        _ = startupEditor(L, init_file, clean);
        if (file_arg) |path| {
            _ = execVimCommand(L, "lua vim._startup_edit = true"); // file-arg event order
            const cmd = std.fmt.allocPrint(gpa, "edit {s}", .{path}) catch unreachable;
            defer gpa.free(cmd);
            _ = execVimCommand(L, cmd);
        }
    } else if (!headless and isInteractive()) {
        // Plain `zigvim`: empty buffer in the terminal UI.
        _ = startupEditor(L, init_file, clean);
    } else {
        std.debug.print("Usage: zigvim <file> [-c <cmd>...] | zigvim -l <script.lua> [-c <cmd>...] | zigvim --embed\n", .{});
        std.process.exit(1);
    }


    // Neovim's order: BufEnter for the first buffer, the -c commands, then VimEnter
    // (unless a -c command quit), and UIEnter only once a UI is attached. `-l` gets none.
    if (lua_script == null) {
        // A file argument already got BufWinEnter from :edit; the empty buffer gets it here.
        if (file_arg == null) fireAutocmd(L, "BufWinEnter");
        fireAutocmd(L, "BufEnter");
        var quit_requested = false;
        for (cmds.items) |cmd| {
            _ = execVimCommand(L, cmd);
            const t = std.mem.trim(u8, cmd, " \t:");
            if (std.mem.eql(u8, t, "q") or std.mem.eql(u8, t, "q!") or std.mem.eql(u8, t, "qa") or
                std.mem.eql(u8, t, "qa!") or std.mem.eql(u8, t, "qall") or std.mem.eql(u8, t, "wq") or
                std.mem.eql(u8, t, "x") or std.mem.eql(u8, t, "wqa")) quit_requested = true;
            if (quit_requested) break;
        }
        if (!quit_requested) {
            c.lua_getglobal(L, "vim");
            c.lua_getfield(L, -1, "v");
            c.lua_pushinteger(L, 1);
            c.lua_setfield(L, -2, "vim_did_enter");
            c.lua_pop(L, 2);
            fireAutocmd(L, "VimEnter");
            if (!headless and isInteractive()) {
                fireAutocmd(L, "UIEnter");
                runTui(L);
            }
        }
    }

    pumpEventLoop(L);
    // Give libuv a chance to finish one-shot deferred callbacks.
    const loop = getLoop();
    _ = c.uv_run(loop, c.UV_RUN_NOWAIT);
}

fn fireAutocmd(L: *c.lua_State, event: [*:0]const u8) void {
    c.lua_getglobal(L, "vim");
    c.lua_getfield(L, -1, "_exec_autocmds");
    c.lua_pushstring(L, event);
    c.lua_newtable(L);
    if (c.lua_pcall(L, 2, 0, 0) != 0) c.lua_pop(L, 1);
    c.lua_pop(L, 1);
}

fn isInteractive() bool {
    return c.isatty(0) != 0 and c.isatty(1) != 0;
}

fn loadTui(L: *c.lua_State) !void {
    const src = @embedFile("tui.lua");
    const z = try g_allocator.dupeSentinel(u8, src, 0);
    defer g_allocator.free(z);
    if (c.luaL_dostring(L, z.ptr)) {
        const err = c.lua_tolstring(L, -1, null);
        if (err != null) std.debug.print("tui error: {s}\n", .{std.mem.span(err)});
        return error.TuiFailed;
    }
}

fn runTui(L: *c.lua_State) void {
    c.lua_getglobal(L, "vim");
    c.lua_getfield(L, -1, "_tui_run");
    if (c.lua_pcall(L, 0, 0, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        if (err != null) std.debug.print("{s}\n", .{std.mem.span(err)});
        c.lua_pop(L, 1);
    }
    c.lua_pop(L, 1);
}

fn execVimCommand(L: *c.lua_State, cmd: []const u8) bool {
    c.lua_getglobal(L, "vim");
    c.lua_getfield(L, -1, "cmd");
    c.lua_pushlstring(L, cmd.ptr, cmd.len);
    if (c.lua_pcall(L, 1, 0, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        if (err != null) std.debug.print("{s}\n", .{std.mem.span(err)});
        c.lua_pop(L, 1);
        c.lua_pop(L, 1);
        return false;
    }
    c.lua_pop(L, 1);
    return true;
}

/// Run the editor startup: an explicit -u init file (if any) first, then
/// Neovim's defaults and runtime plugins. --clean skips the user config but
/// still runs the defaults, matching `nvim --clean`.
fn startupEditor(L: *c.lua_State, init_file: ?[]const u8, clean: bool) bool {
    if (init_file != null and !loadUserConfig(L, init_file)) return false;
    c.lua_getglobal(L, "vim");
    c.lua_getfield(L, -1, "_startup");
    c.lua_pushboolean(L, if (init_file != null or clean) 1 else 0);
    if (c.lua_pcall(L, 1, 1, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        if (err != null) std.debug.print("{s}\n", .{std.mem.span(err)});
        c.lua_pop(L, 1);
        c.lua_pop(L, 1);
        return false;
    }
    c.lua_pop(L, 1);
    c.lua_pop(L, 1);
    return true;
}

fn loadUserConfig(L: *c.lua_State, init_file: ?[]const u8) bool {
    if (init_file) |path| {
        const cpath = g_allocator.dupeSentinel(u8, path, 0) catch return false;
        defer g_allocator.free(cpath);
        if (c.luaL_dofile(L, cpath)) {
            const err = c.lua_tolstring(L, -1, null);
            if (err != null) std.debug.print("Error loading {s}: {s}\n", .{ path, std.mem.span(err) });
            c.lua_pop(L, 1);
            return false;
        }
        return true;
    }

    c.lua_getglobal(L, "vim");
    c.lua_getfield(L, -1, "_load_init");
    if (c.lua_pcall(L, 0, 1, 0) != 0) {
        c.lua_pop(L, 1);
        c.lua_pop(L, 1);
        return false;
    }
    c.lua_pop(L, 1);
    c.lua_pop(L, 1);
    return true;
}

/// Identity for the `vim.NIL` sentinel Neovim uses for JSON null.
var g_nil_sentinel: u8 = 0;

fn pushNilSentinel(L: *c.lua_State) void {
    c.lua_pushlightuserdata(L, @ptrCast(&g_nil_sentinel));
}

fn registerVimGlobal(L: *c.lua_State) !void {
    c.lua_newtable(L);

    pushNilSentinel(L);
    c.lua_setfield(L, -2, "NIL");

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
    c.lua_pushcfunction(L, luaPathType);
    c.lua_setfield(L, -2, "_path_type");
    c.lua_pushcfunction(L, luaBufGetShortName);
    c.lua_setfield(L, -2, "_buf_short_name");
    c.lua_pushcfunction(L, luaBufGetModified);
    c.lua_setfield(L, -2, "_buf_modified");
    c.lua_pushcfunction(L, luaBufSetModified);
    c.lua_setfield(L, -2, "_buf_set_modified");
    c.lua_pushcfunction(L, luaTtyIsatty);
    c.lua_setfield(L, -2, "_tty_isatty");
    c.lua_pushcfunction(L, luaTtyRaw);
    c.lua_setfield(L, -2, "_tty_raw");
    c.lua_pushcfunction(L, luaTtySize);
    c.lua_setfield(L, -2, "_tty_size");
    c.lua_pushcfunction(L, luaTtyRead);
    c.lua_setfield(L, -2, "_tty_read");
    c.lua_pushcfunction(L, luaTtyWrite);
    c.lua_setfield(L, -2, "_tty_write");

    c.lua_newtable(L);
    c.lua_pushcfunction(L, luaUvNewTimer);
    c.lua_setfield(L, -2, "new_timer");
    c.lua_pushcfunction(L, luaUvNewPipe);
    c.lua_setfield(L, -2, "new_pipe");
    c.lua_pushcfunction(L, luaUvSpawn);
    c.lua_setfield(L, -2, "spawn");
    c.lua_pushcfunction(L, luaUvNewCheck);
    c.lua_setfield(L, -2, "new_check");
    c.lua_pushcfunction(L, luaUvKill);
    c.lua_setfield(L, -2, "kill");
    c.lua_pushcfunction(L, luaUvNewFsEvent);
    c.lua_setfield(L, -2, "new_fs_event");
    c.lua_pushcfunction(L, luaUvVersion);
    c.lua_setfield(L, -2, "version");
    c.lua_pushcfunction(L, luaUvVersionString);
    c.lua_setfield(L, -2, "version_string");
    c.lua_pushcfunction(L, luaUvOsUname);
    c.lua_setfield(L, -2, "os_uname");
    c.lua_pushcfunction(L, luaUvCwd);
    c.lua_setfield(L, -2, "cwd");
    c.lua_pushcfunction(L, luaUvChdir);
    c.lua_setfield(L, -2, "chdir");
    c.lua_pushcfunction(L, luaUvOsGetpid);
    c.lua_setfield(L, -2, "os_getpid");
    c.lua_pushcfunction(L, luaUvOsGetppid);
    c.lua_setfield(L, -2, "os_getppid");
    c.lua_pushcfunction(L, luaUvOsHomedir);
    c.lua_setfield(L, -2, "os_homedir");
    c.lua_pushcfunction(L, luaUvExepath);
    c.lua_setfield(L, -2, "exepath");
    c.lua_pushcfunction(L, luaUvOsGetenv);
    c.lua_setfield(L, -2, "os_getenv");
    c.lua_pushcfunction(L, luaUvOsSetenv);
    c.lua_setfield(L, -2, "os_setenv");
    c.lua_pushcfunction(L, luaUvOsEnviron);
    c.lua_setfield(L, -2, "os_environ");
    c.lua_pushcfunction(L, luaUvOsUnsetenv);
    c.lua_setfield(L, -2, "os_unsetenv");
    c.lua_pushcfunction(L, luaUvHrtime);
    c.lua_setfield(L, -2, "hrtime");
    c.lua_pushcfunction(L, luaUvNow);
    c.lua_setfield(L, -2, "now");
    c.lua_pushcfunction(L, luaUvSleep);
    c.lua_setfield(L, -2, "sleep");
    c.lua_pushcfunction(L, luaUvFsRealpath);
    c.lua_setfield(L, -2, "fs_realpath");
    c.lua_pushcfunction(L, luaUvFsMkdir);
    c.lua_setfield(L, -2, "fs_mkdir");
    c.lua_pushcfunction(L, luaUvFsUnlink);
    c.lua_setfield(L, -2, "fs_unlink");
    c.lua_pushcfunction(L, luaUvFsRmdir);
    c.lua_setfield(L, -2, "fs_rmdir");
    c.lua_pushcfunction(L, luaUvFsStat);
    c.lua_setfield(L, -2, "fs_stat");
    c.lua_pushcfunction(L, luaUvFsScandir);
    c.lua_setfield(L, -2, "fs_scandir");
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

// Lua reimplementations of Neovim's Vimscript runtime plugins. They live in
// src/lua/ (not runtime/lua/, which is fetched and gitignored) and are
// embedded so a fresh checkout has them without running fetch-runtime.sh.
const embedded_lua_modules = [_]struct { name: [:0]const u8, source: [:0]const u8 }{
    .{ .name = "vim._matchit_stub", .source = @embedFile("lua/vim/_matchit_stub.lua") },
    .{ .name = "vim._matchparen", .source = @embedFile("lua/vim/_matchparen.lua") },
    .{ .name = "vim._netrw", .source = @embedFile("lua/vim/_netrw.lua") },
    .{ .name = "vim._archives", .source = @embedFile("lua/vim/_archives.lua") },
    .{ .name = "vim._tutor", .source = @embedFile("lua/vim/_tutor.lua") },
    .{ .name = "vim._remote", .source = @embedFile("lua/vim/_remote.lua") },
    .{ .name = "vim._default_hl", .source = @embedFile("lua/vim/_default_hl.lua") },
    .{ .name = "vim._diff", .source = @embedFile("lua/vim/_diff.lua") },
    .{ .name = "vim._regex", .source = @embedFile("lua/vim/_regex.lua") },
};

/// Expose the embedded modules as a global table that prelude.lua turns into a
/// package searcher. Must run after luaL_openlibs and before loadPrelude.
fn registerEmbeddedModules(L: *c.lua_State) void {
    c.lua_newtable(L);
    for (embedded_lua_modules) |module| {
        c.lua_pushlstring(L, module.source.ptr, module.source.len);
        c.lua_setfield(L, -2, module.name.ptr);
    }
    c.lua_setglobal(L, "_ZIGVIM_EMBEDDED");
}

// Like Neovim: lpeg is preloaded into package.loaded.lpeg and exposed as vim.lpeg.
fn registerLpeg(L: *c.lua_State) void {
    c.lua_pushcfunction(L, @as(c.lua_CFunction, @ptrCast(&c.luaopen_lpeg)));
    c.lua_call(L, 0, 1);
    c.lua_getglobal(L, "package");
    c.lua_getfield(L, -1, "loaded");
    c.lua_pushvalue(L, -3);
    c.lua_setfield(L, -2, "lpeg");
    c.lua_pop(L, 2);
    c.lua_getglobal(L, "vim");
    c.lua_pushvalue(L, -2);
    c.lua_setfield(L, -2, "lpeg");
    c.lua_pop(L, 2);
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
        .{ .name = "nvim_buf_get_name", .f = @ptrCast(&luaBufGetName) },
        .{ .name = "nvim_buf_set_name", .f = @ptrCast(&luaBufSetName) },
        .{ .name = "nvim_get_current_buf", .f = @ptrCast(&luaGetCurrentBuf) },
        .{ .name = "nvim_set_current_buf", .f = @ptrCast(&luaSetCurrentBuf) },
        .{ .name = "nvim_get_current_win", .f = @ptrCast(&luaGetCurrentWin) },
        .{ .name = "nvim_set_current_win", .f = @ptrCast(&luaSetCurrentWin) },
        .{ .name = "nvim_win_get_buf", .f = @ptrCast(&luaWinGetBuf) },
        .{ .name = "nvim_win_set_buf", .f = @ptrCast(&luaWinSetBuf) },
        .{ .name = "nvim_win_get_cursor", .f = @ptrCast(&luaWinGetCursor) },
        .{ .name = "nvim_win_set_cursor", .f = @ptrCast(&luaWinSetCursor) },
        .{ .name = "nvim_win_get_height", .f = @ptrCast(&luaWinGetHeight) },
        .{ .name = "nvim_win_get_width", .f = @ptrCast(&luaWinGetWidth) },
        .{ .name = "nvim_win_get_position", .f = @ptrCast(&luaWinGetPosition) },
        .{ .name = "nvim_win_get_number", .f = @ptrCast(&luaWinGetNumber) },
        .{ .name = "nvim_win_is_valid", .f = @ptrCast(&luaWinIsValid) },
        .{ .name = "nvim_list_bufs", .f = @ptrCast(&luaListBufs) },
        .{ .name = "nvim_list_wins", .f = @ptrCast(&luaListWins) },
        .{ .name = "nvim_list_tabpages", .f = @ptrCast(&luaListTabpages) },
        .{ .name = "nvim_get_current_tabpage", .f = @ptrCast(&luaGetCurrentTabpage) },
        .{ .name = "nvim_tabpage_get_number", .f = @ptrCast(&luaTabpageGetNumber) },
        .{ .name = "nvim_tabpage_get_win", .f = @ptrCast(&luaTabpageGetWin) },
        .{ .name = "nvim_tabpage_is_valid", .f = @ptrCast(&luaTabpageIsValid) },
        .{ .name = "nvim_strwidth", .f = @ptrCast(&luaStrWidth) },
        .{ .name = "nvim_get_current_line", .f = @ptrCast(&luaGetCurrentLine) },
        .{ .name = "nvim_set_current_line", .f = @ptrCast(&luaSetCurrentLine) },
        .{ .name = "nvim_del_current_line", .f = @ptrCast(&luaDelCurrentLine) },
        .{ .name = "nvim_get_mode", .f = @ptrCast(&luaGetMode) },
        .{ .name = "nvim_create_augroup", .f = @ptrCast(&luaCreateAugroup) },
        .{ .name = "nvim_create_autocmd", .f = @ptrCast(&luaCreateAutocmd) },
        .{ .name = "nvim_exec_autocmds", .f = @ptrCast(&luaExecAutocmds) },
    };
    inline for (pairs) |p| {
        c.lua_pushcfunction(L, p.f);
        c.lua_setfield(L, -2, p.name);
    }
}

// ------------------------------------------------------------ terminal I/O
// Raw terminal primitives for the Lua TUI (src/tui.lua).

var g_orig_termios: c.struct_termios = undefined;
var g_raw_enabled: bool = false;

fn luaTtyIsatty(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushboolean(LS, if (c.isatty(0) != 0 and c.isatty(1) != 0) 1 else 0);
    return 1;
}

fn luaTtyRaw(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const enable = c.lua_toboolean(LS, 1) != 0;
    if (enable and !g_raw_enabled) {
        if (c.tcgetattr(0, &g_orig_termios) != 0) {
            c.lua_pushboolean(LS, 0);
            return 1;
        }
        var raw = g_orig_termios;
        raw.c_iflag &= ~@as(c.tcflag_t, c.IGNBRK | c.BRKINT | c.PARMRK | c.ISTRIP | c.INLCR | c.IGNCR | c.ICRNL | c.IXON);
        raw.c_oflag &= ~@as(c.tcflag_t, c.OPOST);
        raw.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ECHONL | c.ICANON | c.ISIG | c.IEXTEN);
        raw.c_cflag |= @as(c.tcflag_t, c.CS8);
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(0, c.TCSAFLUSH, &raw) != 0) {
            c.lua_pushboolean(LS, 0);
            return 1;
        }
        g_raw_enabled = true;
    } else if (!enable and g_raw_enabled) {
        _ = c.tcsetattr(0, c.TCSAFLUSH, &g_orig_termios);
        g_raw_enabled = false;
    }
    c.lua_pushboolean(LS, 1);
    return 1;
}

fn luaTtySize(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var ws: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    const req: c_ulong = if (builtin.os.tag == .macos) 0x40087468 else 0x5413;
    var rows: c_int = 24;
    var cols: c_int = 80;
    if (c.ioctl(1, req, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        rows = ws.ws_row;
        cols = ws.ws_col;
    }
    c.lua_pushinteger(LS, rows);
    c.lua_pushinteger(LS, cols);
    return 2;
}

/// Wait up to `timeout` ms for input. Returns "" on timeout, nil on EOF.
fn luaTtyRead(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const timeout: c_int = @intCast(c.luaL_optinteger(LS, 1, 100));
    var pfd = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
    // Wait in slices so vim.schedule / timers (e.g. lazy.nvim's VeryLazy) run while the TUI idles.
    var waited: c_int = 0;
    var ready: c_int = 0;
    while (true) {
        _ = c.uv_run(getLoop(), c.UV_RUN_NOWAIT);
        pumpEventLoop(LS);
        const slice: c_int = @min(10, timeout - waited);
        ready = c.poll(&pfd, 1, @max(slice, 0));
        waited += slice;
        if (ready != 0 or waited >= timeout) break;
    }
    if (ready <= 0) {
        c.lua_pushstring(LS, "");
        return 1;
    }
    var buf: [1024]u8 = undefined;
    const n = c.read(0, &buf, buf.len);
    if (n == 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    if (n < 0) {
        c.lua_pushstring(LS, "");
        return 1;
    }
    c.lua_pushlstring(LS, &buf, @intCast(n));
    return 1;
}

fn luaTtyWrite(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var len: usize = 0;
    const data = c.luaL_checklstring(LS, 1, &len);
    var off: usize = 0;
    while (off < len) {
        const n = c.write(1, data + off, len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    return 0;
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

/// "file", "dir", or "" — mirrors what vim.fn.getftype reports for a path.
fn luaPathType(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_stat(getLoop(), &req, path, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    if (result < 0) {
        c.lua_pushstring(LS, "");
        return 1;
    }
    const mode: u64 = req.statbuf.st_mode;
    if ((mode & c.S_IFMT) == c.S_IFDIR) {
        c.lua_pushstring(LS, "dir");
    } else if ((mode & c.S_IFMT) == c.S_IFREG) {
        c.lua_pushstring(LS, "file");
    } else {
        c.lua_pushstring(LS, "other");
    }
    return 1;
}

fn resolveBufId(id: i64) u32 {
    if (id == 0) return g_current_buf;
    if (id < 0 or id > std.math.maxInt(u32)) return 0;
    return @intCast(id);
}

fn resolveWinId(id: i64) u32 {
    if (id == 0) return g_current_win;
    if (id < 0 or id > std.math.maxInt(u32)) return 0;
    return @intCast(id);
}

fn luaBufIsValid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    const resolved = resolveBufId(id);
    if (g_store) |*s| c.lua_pushboolean(LS, if (s.isValid(resolved)) 1 else 0) else c.lua_pushboolean(LS, if (resolved > 0) 1 else 0);
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
        s.setLines(resolveBufId(id), start, end, repl.items) catch {
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
        const lines = s.getLines(resolveBufId(id), start, end) catch &[_][]u8{};
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
    if (g_store) |*s| c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(s.lineCount(resolveBufId(id))))) else c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaBufDelete(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    if (g_store) |*s| s.delete(resolveBufId(id));
    return 0;
}

fn luaGetCurrentBuf(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_buf)));
    return 1;
}

fn luaBufGetName(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    var name: []const u8 = "";
    if (g_store) |*s| name = s.getName(resolveBufId(id));
    c.lua_pushlstring(LS, name.ptr, name.len);
    return 1;
}

fn luaBufSetName(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    var len: usize = 0;
    const name = c.luaL_checklstring(LS, 2, &len);
    if (g_store) |*s| {
        s.setName(resolveBufId(id), name[0..len]) catch {
            _ = c.luaL_error(LS, "invalid buffer");
            return 0;
        };
    }
    return 0;
}

fn luaBufGetShortName(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    var name: []const u8 = "";
    if (g_store) |*s| name = s.getShortName(resolveBufId(id));
    c.lua_pushlstring(LS, name.ptr, name.len);
    return 1;
}

fn luaBufGetModified(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    const modified = if (g_store) |*s| s.getModified(resolveBufId(id)) else false;
    c.lua_pushboolean(LS, if (modified) 1 else 0);
    return 1;
}

fn luaBufSetModified(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    const value = c.lua_toboolean(LS, 2) != 0;
    if (g_store) |*s| s.setModified(resolveBufId(id), value);
    return 0;
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
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_win)));
    return 1;
}

fn luaSetCurrentWin(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    if (resolveWinId(id) == 1000) g_current_win = 1000;
    return 0;
}

fn luaWinGetBuf(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_win_buf)));
    return 1;
}

fn luaWinSetBuf(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    const buf = c.luaL_checkinteger(LS, 2);
    if (g_store) |*s| {
        if (s.isValid(resolveBufId(buf))) {
            g_win_buf = resolveBufId(buf);
            g_current_buf = g_win_buf;
        }
    }
    return 0;
}

fn luaWinGetCursor(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_newtable(LS);
    c.lua_pushinteger(LS, @intCast(g_cursor_row));
    c.lua_rawseti(LS, -2, 1);
    c.lua_pushinteger(LS, @intCast(g_cursor_col));
    c.lua_rawseti(LS, -2, 2);
    return 1;
}

fn luaWinSetCursor(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    _ = c.luaL_checktype(LS, 2, c.LUA_TTABLE);
    c.lua_rawgeti(LS, 2, 1);
    var row = c.luaL_checkinteger(LS, -1);
    c.lua_pop(LS, 1);
    c.lua_rawgeti(LS, 2, 2);
    var col = c.luaL_checkinteger(LS, -1);
    c.lua_pop(LS, 1);

    const line_count: i64 = if (g_store) |*s| @intCast(s.lineCount(g_current_buf)) else 1;
    if (row < 1) row = 1;
    if (row > line_count) row = line_count;
    if (col < 0) col = 0;
    if (g_store) |*s| {
        const lines = s.getLines(g_current_buf, row - 1, row) catch &[_][]u8{};
        if (lines.len > 0 and col > @as(i64, @intCast(lines[0].len))) col = @intCast(lines[0].len);
    }
    g_cursor_row = row;
    g_cursor_col = col;
    return 0;
}

fn luaWinGetHeight(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_pushinteger(LS, 22);
    return 1;
}

fn luaWinGetWidth(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_pushinteger(LS, 80);
    return 1;
}

fn luaWinGetPosition(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_newtable(LS);
    c.lua_pushinteger(LS, 0);
    c.lua_rawseti(LS, -2, 1);
    c.lua_pushinteger(LS, 0);
    c.lua_rawseti(LS, -2, 2);
    return 1;
}

fn luaWinGetNumber(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_pushinteger(LS, 1);
    return 1;
}

fn luaWinIsValid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    c.lua_pushboolean(LS, if (resolveWinId(id) == 1000) 1 else 0);
    return 1;
}

fn luaListTabpages(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_newtable(LS);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_tab)));
    c.lua_rawseti(LS, -2, 1);
    return 1;
}

fn luaGetCurrentTabpage(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_tab)));
    return 1;
}

fn luaTabpageGetNumber(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_pushinteger(LS, 1);
    return 1;
}

fn luaTabpageGetWin(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    _ = c.luaL_checkinteger(LS, 1);
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_win)));
    return 1;
}

fn luaTabpageIsValid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const id = c.luaL_checkinteger(LS, 1);
    c.lua_pushboolean(LS, if (id == 0 or id == @as(c.lua_Integer, @intCast(g_current_tab))) 1 else 0);
    return 1;
}

/// Display width of a code point in terminal cells, following the same rules
/// Neovim uses (combining marks are zero width, East Asian characters double).
fn codepointCells(cp: u21) u3 {
    if ((cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or
        (cp >= 0x200b and cp <= 0x200f) or cp == 0xfeff)
    {
        return 0;
    }
    if ((cp >= 0x1100 and cp <= 0x115f) or
        (cp >= 0x231a and cp <= 0x231b) or
        (cp >= 0x23e9 and cp <= 0x23ec) or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe19) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd))
    {
        return 2;
    }
    return 1;
}

fn luaStrWidth(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (c.lua_type(LS, 1) != c.LUA_TSTRING) {
        c.lua_pushstring(LS, "Invalid 'text': Expected Lua string");
        _ = c.lua_error(LS);
        return 0;
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(LS, 1, &len) orelse return 0;
    const text = ptr[0..len];
    var width: i64 = 0;
    var i: usize = 0;
    while (i < text.len and text[i] != 0) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + seq_len > text.len) {
            width += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            width += 1;
            i += 1;
            continue;
        };
        width += codepointCells(cp);
        i += seq_len;
    }
    c.lua_pushinteger(LS, @intCast(width));
    return 1;
}

fn luaGetCurrentLine(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var line: []const u8 = "";
    if (g_store) |*s| {
        const lines = s.getLines(g_current_buf, g_cursor_row - 1, g_cursor_row) catch &[_][]u8{};
        if (lines.len > 0) line = lines[0];
    }
    c.lua_pushlstring(LS, line.ptr, line.len);
    return 1;
}

fn luaSetCurrentLine(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var len: usize = 0;
    const line = c.luaL_checklstring(LS, 1, &len);
    if (g_store) |*s| {
        const replacement = [_][]const u8{line[0..len]};
        s.setLines(g_current_buf, g_cursor_row - 1, g_cursor_row, &replacement) catch {};
    }
    return 0;
}

fn luaDelCurrentLine(L: ?*c.lua_State) callconv(.c) c_int {
    _ = L;
    if (g_store) |*s| {
        if (s.lineCount(g_current_buf) > 1) {
            s.setLines(g_current_buf, g_cursor_row - 1, g_cursor_row, &[_][]const u8{}) catch {};
        } else {
            const replacement = [_][]const u8{""};
            s.setLines(g_current_buf, 0, 1, &replacement) catch {};
        }
    }
    return 0;
}

fn luaGetMode(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_newtable(LS);
    c.lua_pushstring(LS, "n");
    c.lua_setfield(LS, -2, "mode");
    c.lua_pushboolean(LS, 0);
    c.lua_setfield(LS, -2, "blocking");
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
    c.lua_pushinteger(LS, @as(c.lua_Integer, @intCast(g_current_win)));
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

fn initCwd() void {
    var size: usize = g_cwd_buf.len;
    if (c.uv_cwd(&g_cwd_buf, &size) != 0) return;
    const len = std.mem.indexOfScalar(u8, &g_cwd_buf, 0) orelse g_cwd_buf.len;
    g_cwd = g_cwd_buf[0..len];
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
    self_ref: c_int = c.LUA_NOREF,
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
    c.lua_pushcfunction(LS, luaTimerIsClosing);
    c.lua_setfield(LS, -2, "is_closing");
    c.lua_pushcfunction(LS, luaTimerIsActive);
    c.lua_setfield(LS, -2, "is_active");
    c.lua_pushcfunction(LS, luaTimerRef);
    c.lua_setfield(LS, -2, "ref");
    c.lua_pushcfunction(LS, luaTimerUnref);
    c.lua_setfield(LS, -2, "unref");
    // Make method lookup work: metatable.__index = metatable.
    c.lua_pushvalue(LS, -1);
    c.lua_setfield(LS, -2, "__index");
    _ = c.lua_setmetatable(LS, -2);
    c.lua_pushvalue(LS, -1);
    box.self_ref = c.luaL_ref(LS, c.LUA_REGISTRYINDEX);
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
        if (c.uv_is_closing(@ptrCast(&box.handle)) != 0) return 0;
        _ = c.uv_timer_stop(&box.handle);
        c.uv_close(@ptrCast(&box.handle), timerCloseCallback);
    }
    return 0;
}

fn luaTimerIsClosing(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = boxFromSelf(LS) orelse {
        c.lua_pushboolean(LS, 1);
        return 1;
    };
    c.lua_pushboolean(LS, if (c.uv_is_closing(@ptrCast(&box.handle)) != 0) 1 else 0);
    return 1;
}

fn luaTimerIsActive(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = boxFromSelf(LS) orelse return 0;
    c.lua_pushboolean(LS, if (c.uv_is_active(@ptrCast(&box.handle)) != 0) 1 else 0);
    return 1;
}

fn luaTimerRef(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (boxFromSelf(LS)) |box| c.uv_ref(@ptrCast(&box.handle));
    return 0;
}

fn luaTimerUnref(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (boxFromSelf(LS)) |box| c.uv_unref(@ptrCast(&box.handle));
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
        uvDetachObject(L, box.self_ref, "__handle");
    }
    std.heap.page_allocator.destroy(box);
}

// ------------------------------------------------- pipes, processes, checks
// A luv-compatible subset (vim.uv.new_pipe / spawn / new_check) for vim.system,
// gitsigns and friends. Objects are Lua tables holding a pointer to a UvBox;
// the box is freed in the close callback.

const UvKind = enum { pipe, process, check, fs_event };

const UvBox = struct {
    kind: UvKind,
    h: extern union { pipe: c.uv_pipe_t, process: c.uv_process_t, check: c.uv_check_t, fs_event: c.uv_fs_event_t } = undefined,
    cb_ref: c_int = c.LUA_NOREF, // read / exit / check callback
    close_ref: c_int = c.LUA_NOREF,
    self_ref: c_int = c.LUA_NOREF, // the Lua object; detached on close so stale calls are safe

    fn handle(self: *UvBox) *c.uv_handle_t {
        return @ptrCast(&self.h);
    }
    fn stream(self: *UvBox) *c.uv_stream_t {
        return @ptrCast(&self.h.pipe);
    }
};

fn uvBoxFromSelf(L: *c.lua_State, idx: c_int) ?*UvBox {
    if (!c.lua_istable(L, idx)) return null;
    _ = c.lua_getfield(L, idx, "__uvbox");
    const ptr = c.lua_touserdata(L, -1);
    c.lua_pop(L, 1);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

fn uvSetRef(L: *c.lua_State, ref: *c_int, idx: c_int) void {
    if (ref.* != c.LUA_NOREF) c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref.*);
    ref.* = c.LUA_NOREF;
    if (c.lua_isfunction(L, idx)) {
        c.lua_pushvalue(L, idx);
        ref.* = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    }
}

/// Calls the function at the top of the stack with nargs arguments below it; errors
/// in callbacks are reported on stderr (Neovim reports them too) instead of lost.
fn uvCall(L: *c.lua_State, nargs: c_int) void {
    if (c.lua_pcall(L, nargs, 0, 0) != 0) {
        const msg = c.lua_tolstring(L, -1, null);
        if (msg != null) std.debug.print("Error executing luv callback:\n{s}\n", .{std.mem.span(msg)});
        c.lua_pop(L, 1);
    }
}

/// luv's failure convention: nil, "ENAME: message", "ENAME".
fn uvPushFail(L: *c.lua_State, rc: c_int) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushfstring(L, "%s: %s", c.uv_err_name(rc), c.uv_strerror(rc));
    c.lua_pushstring(L, c.uv_err_name(rc));
    return 3;
}

fn uvPushObject(L: *c.lua_State, box: *UvBox) void {
    c.lua_newtable(L);
    c.lua_pushlightuserdata(L, box);
    c.lua_setfield(L, -2, "__uvbox");
    c.lua_newtable(L);
    const common = [_]struct { n: [*:0]const u8, f: c.lua_CFunction }{
        .{ .n = "close", .f = @ptrCast(&luaUvHandleClose) },
        .{ .n = "is_closing", .f = @ptrCast(&luaUvHandleIsClosing) },
        .{ .n = "is_active", .f = @ptrCast(&luaUvHandleIsActive) },
        .{ .n = "ref", .f = @ptrCast(&luaUvHandleRef) },
        .{ .n = "unref", .f = @ptrCast(&luaUvHandleUnref) },
        .{ .n = "has_ref", .f = @ptrCast(&luaUvHandleHasRef) },
    };
    for (common) |m| {
        c.lua_pushcfunction(L, m.f);
        c.lua_setfield(L, -2, m.n);
    }
    switch (box.kind) {
        .pipe => {
            const ms = [_]struct { n: [*:0]const u8, f: c.lua_CFunction }{
                .{ .n = "read_start", .f = @ptrCast(&luaUvReadStart) },
                .{ .n = "read_stop", .f = @ptrCast(&luaUvReadStop) },
                .{ .n = "write", .f = @ptrCast(&luaUvWrite) },
                .{ .n = "shutdown", .f = @ptrCast(&luaUvShutdown) },
            };
            for (ms) |m| {
                c.lua_pushcfunction(L, m.f);
                c.lua_setfield(L, -2, m.n);
            }
        },
        .process => {
            c.lua_pushcfunction(L, luaUvProcessKill);
            c.lua_setfield(L, -2, "kill");
            c.lua_pushcfunction(L, luaUvProcessGetPid);
            c.lua_setfield(L, -2, "get_pid");
        },
        .check => {
            c.lua_pushcfunction(L, luaUvCheckStart);
            c.lua_setfield(L, -2, "start");
            c.lua_pushcfunction(L, luaUvCheckStop);
            c.lua_setfield(L, -2, "stop");
        },
        .fs_event => {
            c.lua_pushcfunction(L, luaUvFsEventStart);
            c.lua_setfield(L, -2, "start");
            c.lua_pushcfunction(L, luaUvFsEventStop);
            c.lua_setfield(L, -2, "stop");
        },
    }
    c.lua_pushvalue(L, -1);
    c.lua_setfield(L, -2, "__index");
    _ = c.lua_setmetatable(L, -2);
    c.lua_pushvalue(L, -1);
    box.self_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
}

/// After a close, the Lua object outlives the box: clear its pointer (field) so
/// methods see a closed handle instead of freed memory.
fn uvDetachObject(L: *c.lua_State, ref: c_int, field: [*:0]const u8) void {
    if (ref == c.LUA_NOREF) return;
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref);
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, field);
    c.lua_pop(L, 1);
    c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
}

fn uvNewBox(kind: UvKind) ?*UvBox {
    const box = std.heap.c_allocator.create(UvBox) catch return null;
    box.* = .{ .kind = kind };
    return box;
}

fn uvBoxCloseCb(h: [*c]c.uv_handle_t) callconv(.c) void {
    const box: *UvBox = @ptrCast(@alignCast(h[0].data.?));
    if (g_L) |L| {
        if (box.close_ref != c.LUA_NOREF) {
            c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, box.close_ref);
            uvCall(L, 0);
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, box.close_ref);
        }
        if (box.cb_ref != c.LUA_NOREF) c.luaL_unref(L, c.LUA_REGISTRYINDEX, box.cb_ref);
        uvDetachObject(L, box.self_ref, "__uvbox");
    }
    std.heap.c_allocator.destroy(box);
}

fn luaUvHandleClose(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    if (c.uv_is_closing(box.handle()) != 0) return 0;
    uvSetRef(LS, &box.close_ref, 2);
    c.uv_close(box.handle(), uvBoxCloseCb);
    return 0;
}

fn luaUvHandleIsClosing(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse {
        c.lua_pushboolean(LS, 1);
        return 1;
    };
    c.lua_pushboolean(LS, if (c.uv_is_closing(box.handle()) != 0) 1 else 0);
    return 1;
}

fn luaUvHandleIsActive(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    c.lua_pushboolean(LS, if (c.uv_is_active(box.handle()) != 0) 1 else 0);
    return 1;
}

fn luaUvHandleRef(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (uvBoxFromSelf(LS, 1)) |box| c.uv_ref(box.handle());
    return 0;
}

fn luaUvHandleUnref(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    if (uvBoxFromSelf(LS, 1)) |box| c.uv_unref(box.handle());
    return 0;
}

fn luaUvHandleHasRef(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    c.lua_pushboolean(LS, if (c.uv_has_ref(box.handle()) != 0) 1 else 0);
    return 1;
}

// --- pipes

fn luaUvNewPipe(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const ipc: c_int = if (c.lua_toboolean(LS, 1) != 0) 1 else 0;
    const box = uvNewBox(.pipe) orelse return uvPushFail(LS, c.UV_ENOMEM);
    const rc = c.uv_pipe_init(getLoop(), &box.h.pipe, ipc);
    if (rc != 0) {
        std.heap.c_allocator.destroy(box);
        return uvPushFail(LS, rc);
    }
    box.handle().data = box;
    uvPushObject(LS, box);
    return 1;
}

fn uvAllocCb(_: [*c]c.uv_handle_t, suggested: usize, buf: [*c]c.uv_buf_t) callconv(.c) void {
    const mem = std.heap.c_allocator.alloc(u8, suggested) catch {
        buf[0] = c.uv_buf_init(null, 0);
        return;
    };
    buf[0] = c.uv_buf_init(mem.ptr, @intCast(mem.len));
}

fn uvReadCb(s: [*c]c.uv_stream_t, nread: isize, buf: [*c]const c.uv_buf_t) callconv(.c) void {
    defer if (buf[0].base != null) std.heap.c_allocator.free(buf[0].base[0..buf[0].len]);
    const box: *UvBox = @ptrCast(@alignCast(s[0].data.?));
    const L = g_L orelse return;
    if (nread == 0 or box.cb_ref == c.LUA_NOREF) return;
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, box.cb_ref);
    if (nread > 0) {
        c.lua_pushnil(L);
        c.lua_pushlstring(L, buf[0].base, @intCast(nread));
    } else if (nread == c.UV_EOF) {
        c.lua_pushnil(L);
        c.lua_pushnil(L);
    } else {
        c.lua_pushstring(L, c.uv_err_name(@intCast(nread)));
        c.lua_pushnil(L);
    }
    uvCall(L, 2);
}

fn luaUvReadStart(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    uvSetRef(LS, &box.cb_ref, 2);
    const rc = c.uv_read_start(box.stream(), uvAllocCb, uvReadCb);
    if (rc != 0) return uvPushFail(LS, rc);
    c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaUvReadStop(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    _ = c.uv_read_stop(box.stream());
    c.lua_pushinteger(LS, 0);
    return 1;
}

const UvReq = struct {
    u: extern union { write: c.uv_write_t, shutdown: c.uv_shutdown_t } = undefined,
    data: []u8 = &.{},
    ref: c_int = c.LUA_NOREF,
};

fn uvReqDone(req: *UvReq, status: c_int) void {
    if (g_L) |L| {
        if (req.ref != c.LUA_NOREF) {
            c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, req.ref);
            if (status < 0) c.lua_pushstring(L, c.uv_err_name(status)) else c.lua_pushnil(L);
            uvCall(L, 1);
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, req.ref);
        }
    }
    if (req.data.len > 0) std.heap.c_allocator.free(req.data);
    std.heap.c_allocator.destroy(req);
}

fn uvWriteCb(r: [*c]c.uv_write_t, status: c_int) callconv(.c) void {
    uvReqDone(@ptrCast(@alignCast(r[0].data.?)), status);
}

fn uvShutdownCb(r: [*c]c.uv_shutdown_t, status: c_int) callconv(.c) void {
    uvReqDone(@ptrCast(@alignCast(r[0].data.?)), status);
}

/// pipe:write(data [, cb]): data is a string or a list of strings.
fn luaUvWrite(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    var list = std.ArrayList(u8).initCapacity(std.heap.c_allocator, 0) catch return uvPushFail(LS, c.UV_ENOMEM);
    if (c.lua_istable(LS, 2)) {
        var i: c_int = 1;
        while (true) : (i += 1) {
            c.lua_rawgeti(LS, 2, i);
            if (c.lua_isnil(LS, -1)) {
                c.lua_pop(LS, 1);
                break;
            }
            var n: usize = 0;
            const p = c.luaL_checklstring(LS, -1, &n);
            list.appendSlice(std.heap.c_allocator, p[0..n]) catch {};
            c.lua_pop(LS, 1);
        }
    } else {
        var n: usize = 0;
        const p = c.luaL_checklstring(LS, 2, &n);
        list.appendSlice(std.heap.c_allocator, p[0..n]) catch {};
    }
    const req = std.heap.c_allocator.create(UvReq) catch return uvPushFail(LS, c.UV_ENOMEM);
    req.* = .{ .data = list.toOwnedSlice(std.heap.c_allocator) catch &.{} };
    req.u.write.data = req;
    uvSetRef(LS, &req.ref, 3);
    var buf = c.uv_buf_init(if (req.data.len > 0) req.data.ptr else null, @intCast(req.data.len));
    const rc = c.uv_write(&req.u.write, box.stream(), &buf, 1, uvWriteCb);
    if (rc != 0) {
        if (req.ref != c.LUA_NOREF) c.luaL_unref(LS, c.LUA_REGISTRYINDEX, req.ref);
        if (req.data.len > 0) std.heap.c_allocator.free(req.data);
        std.heap.c_allocator.destroy(req);
        return uvPushFail(LS, rc);
    }
    c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaUvShutdown(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    const req = std.heap.c_allocator.create(UvReq) catch return uvPushFail(LS, c.UV_ENOMEM);
    req.* = .{};
    req.u.shutdown.data = req;
    uvSetRef(LS, &req.ref, 2);
    const rc = c.uv_shutdown(&req.u.shutdown, box.stream(), uvShutdownCb);
    if (rc != 0) {
        if (req.ref != c.LUA_NOREF) c.luaL_unref(LS, c.LUA_REGISTRYINDEX, req.ref);
        std.heap.c_allocator.destroy(req);
        return uvPushFail(LS, rc);
    }
    c.lua_pushinteger(LS, 0);
    return 1;
}

// --- processes

fn uvExitCb(p: [*c]c.uv_process_t, status: i64, signal: c_int) callconv(.c) void {
    const box: *UvBox = @ptrCast(@alignCast(p[0].data.?));
    const L = g_L orelse return;
    if (box.cb_ref == c.LUA_NOREF) return;
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, box.cb_ref);
    c.lua_pushinteger(L, @intCast(status));
    c.lua_pushinteger(L, signal);
    uvCall(L, 2);
}

/// Signal number from an integer or a luv-style name ("sigterm", "SIGKILL", "term").
fn uvSignal(L: *c.lua_State, idx: c_int, default: c_int) c_int {
    if (c.lua_isnumber(L, idx) != 0) return @intCast(c.lua_tointeger(L, idx));
    if (c.lua_isstring(L, idx) == 0) return default;
    const raw = std.mem.span(c.lua_tolstring(L, idx, null));
    var lower: [16]u8 = undefined;
    if (raw.len > lower.len) return default;
    for (raw, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
    var name: []const u8 = lower[0..raw.len];
    if (std.mem.startsWith(u8, name, "sig")) name = name[3..];
    const S = std.posix.SIG;
    const table = .{
        .{ "hup", S.HUP }, .{ "int", S.INT }, .{ "quit", S.QUIT }, .{ "kill", S.KILL },
        .{ "term", S.TERM }, .{ "usr1", S.USR1 }, .{ "usr2", S.USR2 }, .{ "pipe", S.PIPE },
        .{ "alrm", S.ALRM }, .{ "chld", S.CHLD }, .{ "cont", S.CONT }, .{ "stop", S.STOP },
        .{ "tstp", S.TSTP }, .{ "winch", S.WINCH },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intCast(@intFromEnum(entry[1]));
    }
    return default;
}

fn luaUvProcessKill(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    const rc = c.uv_process_kill(&box.h.process, uvSignal(LS, 2, @intCast(@intFromEnum(std.posix.SIG.TERM))));
    if (rc != 0) return uvPushFail(LS, rc);
    c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaUvProcessGetPid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    c.lua_pushinteger(LS, box.h.process.pid);
    return 1;
}

fn luaUvKill(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const pid: c_int = @intCast(c.luaL_checkinteger(LS, 1));
    const rc = c.uv_kill(pid, uvSignal(LS, 2, @intCast(@intFromEnum(std.posix.SIG.TERM))));
    if (rc != 0) return uvPushFail(LS, rc);
    c.lua_pushinteger(LS, 0);
    return 1;
}

/// Copies list entries of the table at idx into NUL-terminated strings, optionally
/// with a leading string, ending with a null pointer (argv/envp layout).
fn uvStringList(L: *c.lua_State, arena: std.mem.Allocator, idx: c_int, first: ?[*:0]const u8) ?[*c][*c]u8 {
    var items = std.ArrayList([*c]u8).initCapacity(arena, 8) catch return null;
    if (first) |f| items.append(arena, @constCast(f)) catch return null;
    if (c.lua_istable(L, idx)) {
        var i: c_int = 1;
        while (true) : (i += 1) {
            c.lua_rawgeti(L, idx, i);
            defer c.lua_pop(L, 1);
            if (c.lua_isnil(L, -1)) break;
            var n: usize = 0;
            const p = c.lua_tolstring(L, -1, &n) orelse continue;
            const copy = arena.dupeSentinel(u8, p[0..n], 0) catch return null;
            items.append(arena, copy.ptr) catch return null;
        }
    }
    items.append(arena, null) catch return null;
    return items.items.ptr;
}

/// uv.spawn(path, {args, stdio, env, cwd, detached, hide}, on_exit) -> handle, pid
fn luaUvSpawn(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts: c.uv_process_options_t = std.mem.zeroes(c.uv_process_options_t);
    opts.file = path;
    opts.exit_cb = uvExitCb;
    var stdio: [3]c.uv_stdio_container_t = std.mem.zeroes([3]c.uv_stdio_container_t);
    opts.stdio = &stdio;
    opts.stdio_count = 3;
    for (&stdio) |*s| s.flags = c.UV_IGNORE;

    if (c.lua_istable(LS, 2)) {
        _ = c.lua_getfield(LS, 2, "args");
        opts.args = uvStringList(LS, arena, c.lua_gettop(LS), path) orelse return uvPushFail(LS, c.UV_ENOMEM);
        c.lua_pop(LS, 1);

        _ = c.lua_getfield(LS, 2, "env");
        if (c.lua_istable(LS, -1)) opts.env = uvStringList(LS, arena, c.lua_gettop(LS), null) orelse return uvPushFail(LS, c.UV_ENOMEM);
        c.lua_pop(LS, 1);

        _ = c.lua_getfield(LS, 2, "cwd");
        if (c.lua_isstring(LS, -1) != 0) {
            const cwd = std.mem.span(c.lua_tolstring(LS, -1, null));
            opts.cwd = (arena.dupeSentinel(u8, cwd, 0) catch return uvPushFail(LS, c.UV_ENOMEM)).ptr;
        }
        c.lua_pop(LS, 1);

        _ = c.lua_getfield(LS, 2, "detached");
        if (c.lua_toboolean(LS, -1) != 0) opts.flags |= c.UV_PROCESS_DETACHED;
        c.lua_pop(LS, 1);
        _ = c.lua_getfield(LS, 2, "hide");
        if (c.lua_toboolean(LS, -1) != 0) opts.flags |= c.UV_PROCESS_WINDOWS_HIDE;
        c.lua_pop(LS, 1);

        _ = c.lua_getfield(LS, 2, "stdio");
        if (c.lua_istable(LS, -1)) {
            const t = c.lua_gettop(LS);
            for (&stdio, 0..) |*s, i| {
                c.lua_rawgeti(LS, t, @intCast(i + 1));
                defer c.lua_pop(LS, 1);
                if (c.lua_isnumber(LS, -1) != 0) {
                    s.flags = c.UV_INHERIT_FD;
                    s.data.fd = @intCast(c.lua_tointeger(LS, -1));
                } else if (uvBoxFromSelf(LS, c.lua_gettop(LS))) |pbox| {
                    s.flags = c.UV_CREATE_PIPE | c.UV_READABLE_PIPE | c.UV_WRITABLE_PIPE;
                    s.data.stream = pbox.stream();
                }
            }
        }
        c.lua_pop(LS, 1);
    }
    if (opts.args == null) opts.args = uvStringList(LS, arena, 0, path) orelse return uvPushFail(LS, c.UV_ENOMEM);

    const box = uvNewBox(.process) orelse return uvPushFail(LS, c.UV_ENOMEM);
    box.handle().data = box;
    uvSetRef(LS, &box.cb_ref, 3);
    const rc = c.uv_spawn(getLoop(), &box.h.process, &opts);
    if (rc != 0) {
        // libuv still initialised the handle; it must be closed, which frees the box.
        c.uv_close(box.handle(), uvBoxCloseCb);
        return uvPushFail(LS, rc);
    }
    uvPushObject(LS, box);
    c.lua_pushinteger(LS, box.h.process.pid);
    return 2;
}

// --- checks (run once per loop iteration)

fn luaUvNewCheck(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvNewBox(.check) orelse return uvPushFail(LS, c.UV_ENOMEM);
    const rc = c.uv_check_init(getLoop(), &box.h.check);
    if (rc != 0) {
        std.heap.c_allocator.destroy(box);
        return uvPushFail(LS, rc);
    }
    box.handle().data = box;
    uvPushObject(LS, box);
    return 1;
}

fn uvCheckCb(h: [*c]c.uv_check_t) callconv(.c) void {
    const box: *UvBox = @ptrCast(@alignCast(h[0].data.?));
    const L = g_L orelse return;
    if (box.cb_ref == c.LUA_NOREF) return;
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, box.cb_ref);
    uvCall(L, 0);
}

fn luaUvCheckStart(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    uvSetRef(LS, &box.cb_ref, 2);
    _ = c.uv_check_start(&box.h.check, uvCheckCb);
    c.lua_pushinteger(LS, 0);
    return 1;
}

// --- fs_event (directory/file watchers)

fn luaUvNewFsEvent(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvNewBox(.fs_event) orelse return uvPushFail(LS, c.UV_ENOMEM);
    const rc = c.uv_fs_event_init(getLoop(), &box.h.fs_event);
    if (rc != 0) {
        std.heap.c_allocator.destroy(box);
        return uvPushFail(LS, rc);
    }
    box.handle().data = box;
    uvPushObject(LS, box);
    return 1;
}

fn uvFsEventCb(h: [*c]c.uv_fs_event_t, filename: [*c]const u8, events: c_int, status: c_int) callconv(.c) void {
    const box: *UvBox = @ptrCast(@alignCast(h[0].data.?));
    const L = g_L orelse return;
    if (box.cb_ref == c.LUA_NOREF) return;
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, box.cb_ref);
    if (status < 0) c.lua_pushstring(L, c.uv_err_name(status)) else c.lua_pushnil(L);
    if (filename != null) c.lua_pushstring(L, filename) else c.lua_pushnil(L);
    c.lua_newtable(L);
    if (events & c.UV_CHANGE != 0) {
        c.lua_pushboolean(L, 1);
        c.lua_setfield(L, -2, "change");
    }
    if (events & c.UV_RENAME != 0) {
        c.lua_pushboolean(L, 1);
        c.lua_setfield(L, -2, "rename");
    }
    uvCall(L, 3);
}

/// fs_event:start(path, {recursive=}, cb(err, filename, {change=, rename=}))
fn luaUvFsEventStart(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    const path = c.luaL_checklstring(LS, 2, null);
    var flags: c_uint = 0;
    if (c.lua_istable(LS, 3)) {
        _ = c.lua_getfield(LS, 3, "recursive");
        if (c.lua_toboolean(LS, -1) != 0) flags |= c.UV_FS_EVENT_RECURSIVE;
        c.lua_pop(LS, 1);
    }
    uvSetRef(LS, &box.cb_ref, 4);
    const rc = c.uv_fs_event_start(&box.h.fs_event, uvFsEventCb, path, flags);
    if (rc != 0) return uvPushFail(LS, rc);
    c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaUvFsEventStop(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    _ = c.uv_fs_event_stop(&box.h.fs_event);
    c.lua_pushinteger(LS, 0);
    return 1;
}

fn luaUvCheckStop(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const box = uvBoxFromSelf(LS, 1) orelse return 0;
    _ = c.uv_check_stop(&box.h.check);
    c.lua_pushinteger(LS, 0);
    return 1;
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

// vim.uv.chdir(path): true, or nil + error name like luv.
fn luaUvChdir(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    const rc = c.uv_chdir(path);
    if (rc != 0) {
        c.lua_pushnil(LS);
        c.lua_pushstring(LS, c.uv_err_name(rc));
        return 2;
    }
    c.lua_pushboolean(LS, 1);
    return 1;
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

fn luaUvOsGetpid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, c.uv_os_getpid());
    return 1;
}

fn luaUvOsGetppid(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushinteger(LS, c.uv_os_getppid());
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

fn luaUvExepath(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var buf: [4096]u8 = undefined;
    var size: usize = buf.len;
    if (c.uv_exepath(&buf, &size) != 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    c.lua_pushlstring(LS, &buf, size);
    return 1;
}

fn luaUvOsGetenv(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const name = c.luaL_checklstring(LS, 1, null);
    var buf: [4096]u8 = undefined;
    var size: usize = buf.len;
    const result = c.uv_os_getenv(name, &buf, &size);
    if (result == c.UV_ENOENT) {
        c.lua_pushnil(LS);
        return 1;
    }
    if (result != 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse size;
    c.lua_pushlstring(LS, &buf, len);
    return 1;
}

fn luaUvOsEnviron(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    var items: [*c]c.uv_env_item_t = undefined;
    var count: c_int = 0;
    c.lua_newtable(LS);
    if (c.uv_os_environ(&items, &count) != 0) return 1;
    defer c.uv_os_free_environ(items, count);
    var k: usize = 0;
    while (k < @as(usize, @intCast(count))) : (k += 1) {
        c.lua_pushstring(LS, items[k].name);
        c.lua_pushstring(LS, items[k].value);
        c.lua_settable(LS, -3);
    }
    return 1;
}

fn luaUvOsSetenv(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const name = c.luaL_checklstring(LS, 1, null);
    const value = c.luaL_checklstring(LS, 2, null);
    c.lua_pushboolean(LS, if (c.uv_os_setenv(name, value) == 0) 1 else 0);
    return 1;
}

fn luaUvOsUnsetenv(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const name = c.luaL_checklstring(LS, 1, null);
    c.lua_pushboolean(LS, if (c.uv_os_unsetenv(name) == 0) 1 else 0);
    return 1;
}

fn luaUvHrtime(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushnumber(LS, @floatFromInt(c.uv_hrtime()));
    return 1;
}

fn luaUvNow(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    c.lua_pushnumber(LS, @floatFromInt(c.uv_now(getLoop())));
    return 1;
}

fn luaUvSleep(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const ms = c.luaL_checkinteger(LS, 1);
    if (ms > 0) c.uv_sleep(@intCast(ms));
    return 0;
}

fn luaUvFsRealpath(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_realpath(getLoop(), &req, path, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    if (result != 0 or req.ptr == null) {
        c.lua_pushnil(LS);
        return 1;
    }
    const resolved: [*:0]const u8 = @ptrCast(req.ptr.?);
    c.lua_pushstring(LS, resolved);
    return 1;
}

fn fsResultString(L: *c.lua_State, result: c_int) c_int {
    if (result == 0) {
        c.lua_pushnil(L);
        return 1;
    }
    c.lua_pushstring(L, c.uv_strerror(result));
    return 1;
}

fn luaUvFsMkdir(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    const mode: c_int = @intCast(c.luaL_optinteger(LS, 2, 0o777));
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_mkdir(getLoop(), &req, path, mode, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    return fsResultString(LS, result);
}

fn luaUvFsUnlink(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_unlink(getLoop(), &req, path, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    return fsResultString(LS, result);
}

fn luaUvFsRmdir(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_rmdir(getLoop(), &req, path, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    return fsResultString(LS, result);
}

fn luaUvFsStat(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_stat(getLoop(), &req, path, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    if (result != 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    const mode: u64 = req.statbuf.st_mode;
    c.lua_newtable(LS);
    if ((mode & c.S_IFMT) == c.S_IFDIR) {
        c.lua_pushstring(LS, "directory");
    } else if ((mode & c.S_IFMT) == c.S_IFREG) {
        c.lua_pushstring(LS, "file");
    } else if ((mode & c.S_IFMT) == c.S_IFLNK) {
        c.lua_pushstring(LS, "link");
    } else {
        c.lua_pushstring(LS, "other");
    }
    c.lua_setfield(LS, -2, "type");
    c.lua_pushnumber(LS, @floatFromInt(req.statbuf.st_size));
    c.lua_setfield(LS, -2, "size");
    c.lua_pushnumber(LS, @floatFromInt(req.statbuf.st_mtim.tv_sec));
    c.lua_setfield(LS, -2, "mtime");
    return 1;
}

fn luaUvFsScandir(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    const path = c.luaL_checklstring(LS, 1, null);
    var req: c.uv_fs_t = std.mem.zeroes(c.uv_fs_t);
    const result = c.uv_fs_scandir(getLoop(), &req, path, 0, null);
    defer _ = c.uv_fs_req_cleanup(&req);
    if (result < 0) {
        c.lua_pushnil(LS);
        return 1;
    }
    c.lua_newtable(LS);
    var entry: c.uv_dirent_t = undefined;
    var index: c_int = 1;
    while (c.uv_fs_scandir_next(&req, &entry) != c.UV_EOF) {
        c.lua_pushstring(LS, entry.name);
        c.lua_rawseti(LS, -2, index);
        index += 1;
    }
    return 1;
}

fn luaMpackEncode(L: ?*c.lua_State) callconv(.c) c_int {
    const LS: *c.lua_State = @ptrCast(L.?);
    // Neovim refuses to encode a bare nil: there is nothing to write.
    if (c.lua_gettop(LS) < 1 or c.lua_type(LS, 1) == c.LUA_TNIL) {
        c.lua_pushstring(LS, "can't serialize object of type 0");
        _ = c.lua_error(LS);
        return 0;
    }
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
        c.LUA_TLIGHTUSERDATA => {
            if (c.lua_touserdata(L, abs) == @as(?*anyopaque, @ptrCast(&g_nil_sentinel))) {
                try msgpack.encodeNil(a, buf);
            } else {
                return error.UnsupportedType;
            }
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
        .nil => pushNilSentinel(L),
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
