const std = @import("std");
const c = @import("c");
const uv = @import("platform/uv.zig");

// Debug logging to file using C stdio
var debug_log_file_main: ?*c.FILE = null;
fn debugLogMain(comptime fmt: []const u8, args: anytype) void {
    if (debug_log_file_main == null) {
        debug_log_file_main = c.fopen("/tmp/zigvim-debug.log", "a");
        if (debug_log_file_main == null) return;
    }
    const f = debug_log_file_main.?;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.fwrite(msg.ptr, 1, msg.len, f);
    _ = c.fflush(f);
}

// Helper to call lua_tolstring and get string
inline fn luaToString(L: *c.lua_State, idx: c_int) ?[*:0]const u8 {
    var len: usize = 0;
    const result = c.lua_tolstring(L, idx, &len);
    if (@intFromPtr(result) == 0) return null;
    return result;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try std.process.Args.toSlice(init.minimal.args, arena);

    var lua_script: ?[:0]const u8 = null;
    var embed_mode: bool = false;
    var i: usize = 1; // skip argv[0]

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            const ver = uv.getVersion();
            std.debug.print("zigvim v0.1.0\n", .{});
            std.debug.print("libuv v{d}.{d}.{d}\n", .{ ver.major, ver.minor, ver.patch });
            return;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            // no-op
        } else if (std.mem.eql(u8, arg, "--clean")) {
            // no-op
        } else if (std.mem.eql(u8, arg, "--embed")) {
            embed_mode = true;
        } else if (std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                lua_script = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                i += 1; // skip command
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            // filename argument - ignore for now
        }
    }

    if (lua_script) |script_path| {
        try runLuaScript(script_path, gpa, io, arena);
    } else if (embed_mode) {
        try runRpcServer(gpa, io);
    } else {
        // No Lua script or embed mode - print help message
        std.debug.print(
            \\zigvim v0.1.0 - Neovim-compatible editor in Zig
            \\
            \\Usage: zigvim [options] [file]
            \\
            \\Options:
            \\  --version     Show version information
            \\  --headless    Run in headless mode (no UI)
            \\  --embed       Start RPC server on stdin/stdout
            \\  --clean       Start with default config
            \\  -l <script>   Execute Lua script
            \\  -c <command>  Execute command after loading
            \\
            \\Examples:
            \\  zigvim -l test.lua -c "qa!"   Run Lua test script
            \\  zigvim --embed                Start RPC server
            \\  zigvim --version              Show version
            \\
            \\Note: TUI mode not yet implemented. Use --embed with external UI client.
            \\
        , .{});
    }
}

fn runRpcServer(gpa: std.mem.Allocator, io: std.Io) !void {
    _ = gpa;
    _ = io;
    // TODO: Implement msgpack-RPC server
    std.debug.print("zigvim RPC server starting...\n", .{});
    std.debug.print("Listening on stdin/stdout for msgpack-RPC messages\n", .{});
    std.debug.print("TODO: Implement proper msgpack-RPC protocol\n", .{});
    std.debug.print("Exiting (stub implementation)\n", .{});
}

fn runLuaScript(script_path: [:0]const u8, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !void {
    const abs_path = if (std.fs.path.isAbsolute(script_path))
        script_path
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        break :blk try std.fs.path.join(arena, &.{ cwd, script_path });
    };

    const script = try std.Io.Dir.cwd().readFileAlloc(io, abs_path, arena, .limited(1024 * 1024));

    const state = c.luaL_newstate() orelse {
        std.debug.print("Failed to initialize LuaJIT\n", .{});
        return error.LuaInitFailed;
    };
    defer c.lua_close(state);

    c.luaL_openlibs(state);

    try setupPackagePath(state);
    try setupVimUv(state);
    try setupVimJson(state);
    try setupVimVersion(state);
    try setupVimFn(state);
    try setupVimInspect(state);
    try setupVimApi(state);
    try setupVimOptions(state);
    try setupVimVariables(state);
    try setupVimEventLoop(state);

    if (c.luaL_loadbuffer(state, script.ptr, script.len, "@script") != 0) {
        const err = luaToString(state, -1);
        if (err) |e| {
            std.debug.print("Lua load error: {s}\n", .{e});
        }
        return error.LuaError;
    }
    if (c.lua_pcall(state, 0, c.LUA_MULTRET, 0) != 0) {
        const err = luaToString(state, -1);
        if (err) |e| {
            std.debug.print("Lua runtime error: {s}\n", .{e});
        }
        return error.LuaError;
    }

    // TASK-INFRA-002: Pump the event loop to execute scheduled/deferred callbacks
    // Run until there are no more active handles
    pumpEventLoop();
}

/// Pump the libuv event loop to execute any pending timers and async callbacks.
/// This is called after Lua script execution to process vim.schedule/vim.defer_fn.
fn pumpEventLoop() void {
    const loop = c.uv_default_loop();

    // Keep running while there are active handles
    while (c.uv_loop_alive(loop) != 0) {
        // Run one iteration of the event loop
        _ = c.uv_run(loop, c.UV_RUN_ONCE);
    }

    // Final cleanup run to process any remaining callbacks
    _ = c.uv_run(loop, c.UV_RUN_NOWAIT);
}

fn setupVimApi(L: *c.lua_State) !void {
    const api_lua =
        \\vim = vim or {}
        \\vim.api = vim.api or {}
        \\
        \\local _buffers = {}
        \\local _next_buf_id = 1
        \\local _current_buf = nil
        \\local _current_win = 1000
        \\local _augroups = {}
        \\local _next_augroup_id = 1
        \\local _autocmds = {}
        \\local _next_autocmd_id = 1
        \\
        \\_buffers[1] = { lines = {""}, valid = true, listed = true, scratch = false }
        \\_current_buf = 1
        \\_next_buf_id = 2
        \\
        \\vim.api.nvim_get_current_buf = function() return _current_buf end
        \\vim.api.nvim_get_current_win = function() return _current_win end
        \\vim.api.nvim_set_current_buf = function(buf)
        \\  if _buffers[buf] and _buffers[buf].valid then _current_buf = buf end
        \\end
        \\vim.api.nvim_create_buf = function(listed, scratch)
        \\  local id = _next_buf_id
        \\  _next_buf_id = _next_buf_id + 1
        \\  _buffers[id] = { lines = {""}, valid = true, listed = listed, scratch = scratch }
        \\  return id
        \\end
        \\vim.api.nvim_buf_is_valid = function(buf) return _buffers[buf] ~= nil and _buffers[buf].valid end
        \\vim.api.nvim_buf_line_count = function(buf)
        \\  if _buffers[buf] and _buffers[buf].valid then return #_buffers[buf].lines end
        \\  return 0
        \\end
        \\vim.api.nvim_buf_set_lines = function(buf, start, _end, strict_indexing, replacement)
        \\  if not _buffers[buf] or not _buffers[buf].valid then return end
        \\  local lines = _buffers[buf].lines
        \\  local n = #lines
        \\  if start < 0 then start = n + start + 1 end
        \\  if _end < 0 then _end = n + _end + 1 end
        \\  start = start + 1
        \\  local new_lines = {}
        \\  for i = 1, start - 1 do table.insert(new_lines, lines[i]) end
        \\  for _, line in ipairs(replacement) do table.insert(new_lines, line) end
        \\  for i = _end + 1, n do table.insert(new_lines, lines[i]) end
        \\  _buffers[buf].lines = new_lines
        \\end
        \\vim.api.nvim_buf_get_lines = function(buf, start, _end, strict_indexing)
        \\  if not _buffers[buf] or not _buffers[buf].valid then return {} end
        \\  local lines = _buffers[buf].lines
        \\  local n = #lines
        \\  if start < 0 then start = n + start + 1 end
        \\  if _end < 0 then _end = n + _end + 1 end
        \\  start = start + 1
        \\  local result = {}
        \\  for i = start, _end do
        \\    if i >= 1 and i <= n then table.insert(result, lines[i]) end
        \\  end
        \\  return result
        \\end
        \\vim.api.nvim_buf_delete = function(buf, opts)
        \\  if _buffers[buf] then _buffers[buf].valid = false end
        \\end
        \\vim.api.nvim_create_augroup = function(name, opts)
        \\  if opts and opts.clear then
        \\    for id, ac in pairs(_autocmds) do if ac.group == name then _autocmds[id] = nil end end
        \\  end
        \\  _augroups[name] = _next_augroup_id
        \\  _next_augroup_id = _next_augroup_id + 1
        \\  return _augroups[name]
        \\end
        \\vim.api.nvim_create_autocmd = function(event, opts)
        \\  local id = _next_autocmd_id
        \\  _next_autocmd_id = _next_autocmd_id + 1
        \\  _autocmds[id] = { event = event, group = opts.group, pattern = opts.pattern, callback = opts.callback }
        \\  return id
        \\end
        \\vim.api.nvim_exec_autocmds = function(event, opts)
        \\  local pattern = opts and opts.pattern or "*"
        \\  for id, ac in pairs(_autocmds) do
        \\    local match_event = false
        \\    if type(ac.event) == "table" then
        \\      for _, e in ipairs(ac.event) do if e == event then match_event = true; break end end
        \\    else
        \\      match_event = (ac.event == event)
        \\    end
        \\    if match_event and ac.pattern == pattern and ac.callback then ac.callback() end
        \\  end
        \\end
    ;

    if (c.luaL_dostring(L, api_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.api: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

fn setupVimOptions(L: *c.lua_State) !void {
    const opts_lua =
        \\vim = vim or {}
        \\local _options = { number = false, wrap = true, tabstop = 8, shiftwidth = 8, expandtab = false, relativenumber = false, signcolumn = "auto" }
        \\vim.o = setmetatable({}, { __index = function(_, key) return _options[key] end, __newindex = function(_, key, value) _options[key] = value end })
        \\vim.opt = setmetatable({}, { __index = function(_, key) return _options[key] end, __newindex = function(_, key, value) _options[key] = value end })
        \\vim.bo = setmetatable({}, { __index = function(_, key) return _options[key] end, __newindex = function(_, key, value) _options[key] = value end })
        \\vim.wo = setmetatable({}, { __index = function(_, key) return _options[key] end, __newindex = function(_, key, value) _options[key] = value end })
    ;

    if (c.luaL_dostring(L, opts_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.o: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

fn setupVimVariables(L: *c.lua_State) !void {
    const vars_lua =
        \\vim = vim or {}
        \\local _global_vars = {}
        \\local _buf_vars = {}
        \\local _win_vars = {}
        \\local _tab_vars = {}
        \\vim.g = setmetatable({}, { __index = function(_, key) return _global_vars[key] end, __newindex = function(_, key, value) _global_vars[key] = value end })
        \\vim.b = setmetatable({}, { __index = function(_, key) local buf = vim.api.nvim_get_current_buf(); _buf_vars[buf] = _buf_vars[buf] or {}; return _buf_vars[buf][key] end, __newindex = function(_, key, value) local buf = vim.api.nvim_get_current_buf(); _buf_vars[buf] = _buf_vars[buf] or {}; _buf_vars[buf][key] = value end })
        \\vim.w = setmetatable({}, { __index = function(_, key) local win = vim.api.nvim_get_current_win(); _win_vars[win] = _win_vars[win] or {}; return _win_vars[win][key] end, __newindex = function(_, key, value) local win = vim.api.nvim_get_current_win(); _win_vars[win] = _win_vars[win] or {}; _win_vars[win][key] = value end })
        \\vim.t = setmetatable({}, { __index = function(_, key) return _tab_vars[key] end, __newindex = function(_, key, value) _tab_vars[key] = value end })
    ;

    if (c.luaL_dostring(L, vars_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.g: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

// ============================================================================
// TASK-INFRA-002: libuv-based event loop
// ============================================================================

/// Timer data stored in malloc'd memory (survives across callbacks)
const TimerData = struct {
    timer: c.uv_timer_t,
    L: *c.lua_State,
    callback_ref: c_int,
    auto_close: bool,
};

/// Timer callback - called when timer fires
fn uvTimerCallback(handle: ?*c.uv_timer_t) callconv(.c) void {
    const h = handle orelse return;
    const data: *TimerData = @ptrCast(@alignCast(h.*.data));
    const L = data.L;

    // Get the callback from registry
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, data.callback_ref);
    if (c.lua_pcall(L, 0, 0, 0) != 0) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Timer callback error: {s}\n", .{e});
        }
        _ = c.lua_pop(L, 1);
    }

    // Auto-close for one-shot timers (schedule, defer_fn)
    if (data.auto_close) {
        c.uv_close(@ptrCast(&data.timer), @ptrCast(&uvTimerAutoCloseCb));
    }
}

/// Close callback for auto-closing timers
fn uvTimerAutoCloseCb(handle: ?*c.uv_handle_t) callconv(.c) void {
    const h = handle orelse return;
    const data: *TimerData = @ptrCast(@alignCast(h.*.data));
    const L = data.L;

    // Unreference the callback
    if (data.callback_ref != c.LUA_NOREF) {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, data.callback_ref);
    }

    // Free the data
    c.free(data);
}

/// Close callback for manual close (timer:close())
fn uvTimerManualCloseCb(handle: ?*c.uv_handle_t) callconv(.c) void {
    const h = handle orelse return;
    const data: *TimerData = @ptrCast(@alignCast(h.*.data));
    const L = data.L;

    if (data.callback_ref != c.LUA_NOREF) {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, data.callback_ref);
    }

    c.free(data);
}

/// vim.uv.new_timer() - create a new libuv timer
fn luaNewTimer(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;

    // Allocate timer data
    const data: *TimerData = @ptrCast(@alignCast(c.malloc(@sizeOf(TimerData))));
    data.* = .{
        .timer = undefined,
        .L = state,
        .callback_ref = c.LUA_NOREF,
        .auto_close = false,
    };

    // Initialize the timer on default loop
    const result = c.uv_timer_init(c.uv_default_loop(), &data.timer);
    if (result != 0) {
        c.free(data);
        return c.luaL_error(state, "Failed to create timer");
    }
    data.timer.data = data;

    // Create a table to represent the timer object
    c.lua_newtable(state);

    // Store the data pointer as light userdata
    c.lua_pushlightuserdata(state, data);
    c.lua_setfield(state, -2, "_handle");

    // Add methods
    _ = c.lua_pushstring(state, "start");
    _ = c.lua_pushcfunction(state, @as(c.lua_CFunction, @ptrCast(&luaTimerStart)));
    c.lua_settable(state, -3);

    _ = c.lua_pushstring(state, "stop");
    _ = c.lua_pushcfunction(state, @as(c.lua_CFunction, @ptrCast(&luaTimerStop)));
    c.lua_settable(state, -3);

    _ = c.lua_pushstring(state, "close");
    _ = c.lua_pushcfunction(state, @as(c.lua_CFunction, @ptrCast(&luaTimerClose)));
    c.lua_settable(state, -3);

    _ = c.lua_pushstring(state, "is_active");
    _ = c.lua_pushcfunction(state, @as(c.lua_CFunction, @ptrCast(&luaTimerIsActive)));
    c.lua_settable(state, -3);

    return 1;
}

/// timer:start(timeout, repeat, callback)
fn luaTimerStart(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;

    // Get handle from self
    _ = c.lua_getfield(state, 1, "_handle");
    const data: *TimerData = @ptrCast(@alignCast(c.lua_touserdata(state, -1)));
    _ = c.lua_pop(state, 1);

    const timeout: u64 = @intFromFloat(c.lua_tonumber(state, 2));
    const repeat_interval: u64 = @intFromFloat(c.lua_tonumber(state, 3));

    // Unreference old callback if any
    if (data.callback_ref != c.LUA_NOREF) {
        c.luaL_unref(state, c.LUA_REGISTRYINDEX, data.callback_ref);
    }

    // Store callback in registry
    c.lua_pushvalue(state, 4);
    data.callback_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);
    data.auto_close = false; // manual timer, user controls lifecycle

    const result = c.uv_timer_start(&data.timer, @ptrCast(&uvTimerCallback), timeout, repeat_interval);
    if (result != 0) {
        return c.luaL_error(state, "Failed to start timer");
    }

    return 0;
}

/// timer:stop()
fn luaTimerStop(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;

    _ = c.lua_getfield(state, 1, "_handle");
    const data: *TimerData = @ptrCast(@alignCast(c.lua_touserdata(state, -1)));
    _ = c.lua_pop(state, 1);

    _ = c.uv_timer_stop(&data.timer);

    return 0;
}

/// timer:close(callback?)
fn luaTimerClose(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;

    _ = c.lua_getfield(state, 1, "_handle");
    const data: *TimerData = @ptrCast(@alignCast(c.lua_touserdata(state, -1)));
    _ = c.lua_pop(state, 1);

    // If callback provided, call it after close
    // For simplicity, we ignore the callback and just close
    c.uv_close(@ptrCast(&data.timer), @ptrCast(&uvTimerManualCloseCb));

    return 0;
}

/// timer:is_active()
fn luaTimerIsActive(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;

    _ = c.lua_getfield(state, 1, "_handle");
    const data: *TimerData = @ptrCast(@alignCast(c.lua_touserdata(state, -1)));
    _ = c.lua_pop(state, 1);

    const active = c.uv_is_active(@ptrCast(&data.timer));
    c.lua_pushboolean(state, active);
    return 1;
}

fn setupVimUv(L: *c.lua_State) !void {
    // Create vim.uv table
    _ = c.lua_getglobal(L, "vim");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        c.lua_newtable(L);
        c.lua_setglobal(L, "vim");
        _ = c.lua_getglobal(L, "vim");
    }

    _ = c.lua_getfield(L, -1, "uv");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        c.lua_newtable(L);
        c.lua_setfield(L, -2, "uv");
        _ = c.lua_getfield(L, -1, "uv");
    }

    // vim.uv.new_timer = luaNewTimer
    _ = c.lua_pushstring(L, "new_timer");
    _ = c.lua_pushcfunction(L, @as(c.lua_CFunction, @ptrCast(&luaNewTimer)));
    c.lua_settable(L, -3);

    c.lua_pop(L, 2); // pop vim.uv and vim

    // Rest of vim.uv functions via Lua string
    const uv_mock_lua =
        \\vim = vim or {}
        \\vim.uv = vim.uv or {}
        \\vim.uv.os_uname = function()
        \\  local h = io.popen("uname -s -r -v -m 2>/dev/null")
        \\  if h then
        \\    local line = h:read("*l")
        \\    h:close()
        \\    if line then
        \\      local parts = {}
        \\      for part in string.gmatch(line, "[^ ]+") do table.insert(parts, part) end
        \\      if #parts >= 4 then
        \\        local version_parts = {}
        \\        for i = 3, #parts - 1 do table.insert(version_parts, parts[i]) end
        \\        return {
        \\          sysname = parts[1],
        \\          release = parts[2],
        \\          version = table.concat(version_parts, " "),
        \\          machine = parts[#parts]
        \\        }
        \\      end
        \\    end
        \\  end
        \\  return { sysname = "Unknown" }
        \\end
        \\vim.uv.cwd = function() return os.getenv("PWD") or "." end
        \\vim.uv.os_homedir = function() return os.getenv("HOME") or "/tmp" end
        \\vim.uv.os_getenv = function(name) return os.getenv(name) end
        \\vim.uv.fs_stat = function(path) local f = io.open(path, "r"); if f then f:close(); return { type = "file" } end; local h = io.popen("test -d '" .. path .. "' && echo dir"); local is_dir = h:read("*l"); h:close(); if is_dir == "dir" then return { type = "directory" } end; return nil end
        \\vim.uv.fs_lstat = function(path) return vim.uv.fs_stat(path) end
        \\vim.uv.fs_realpath = function(path) local h = io.popen("realpath '" .. path .. "' 2>/dev/null"); local r = h:read("*l"); h:close(); return r or path end
        \\vim.uv.hrtime = function() return os.clock() * 1e9 end
    ;

    if (c.luaL_dostring(L, uv_mock_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.uv: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

/// WaitData - data structure for vim.wait
const WaitData = struct {
    L: *c.lua_State,
    condition_ref: c_int,
    interval_timer: c.uv_timer_t,
    timeout_timer: c.uv_timer_t,
    done: bool,
    success: bool,
    interval: u64,
};

/// Interval timer callback - check condition
fn vimWaitIntervalCallback(handle: ?*c.uv_timer_t) callconv(.c) void {
    const h = handle orelse return;
    const data: *WaitData = @ptrCast(@alignCast(h.*.data));
    const L = data.L;

    // Call the condition function
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, data.condition_ref);
    if (c.lua_pcall(L, 0, 1, 0) != 0) {
        // Error in condition, treat as false
        _ = c.lua_pop(L, 1);
        return;
    }

    // Check if result is truthy
    const result = c.lua_toboolean(L, -1);
    _ = c.lua_pop(L, 1);

    if (result != 0) {
        data.success = true;
        data.done = true;
        // Stop both timers
        _ = c.uv_timer_stop(&data.interval_timer);
        _ = c.uv_timer_stop(&data.timeout_timer);
    }
}

/// Timeout timer callback - set done flag
fn vimWaitTimeoutCallback(handle: ?*c.uv_timer_t) callconv(.c) void {
    const h = handle orelse return;
    const data: *WaitData = @ptrCast(@alignCast(h.*.data));
    data.done = true;
    data.success = false;
    // Stop interval timer
    _ = c.uv_timer_stop(&data.interval_timer);
}

/// vim.wait(timeout, condition, interval, fast_break)
/// C implementation that pumps the event loop
fn luaVimWait(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;

    const timeout: u64 = @intFromFloat(c.lua_tonumber(state, 1));
    const has_condition = !c.lua_isnil(state, 2);
    const interval: u64 = if (c.lua_isnil(state, 3)) 200 else @intFromFloat(c.lua_tonumber(state, 3));

    // If no condition, just sleep
    if (!has_condition) {
        // Create a one-shot timer
        var wait_data: WaitData = .{
            .L = state,
            .condition_ref = c.LUA_NOREF,
            .interval_timer = undefined,
            .timeout_timer = undefined,
            .done = false,
            .success = true,
            .interval = 0,
        };

        _ = c.uv_timer_init(c.uv_default_loop(), &wait_data.timeout_timer);
        wait_data.timeout_timer.data = &wait_data;
        _ = c.uv_timer_start(&wait_data.timeout_timer, @ptrCast(&vimWaitTimeoutCallback), timeout, 0);

        // Pump event loop until done
        while (!wait_data.done) {
            _ = c.uv_run(c.uv_default_loop(), c.UV_RUN_ONCE);
        }

        // Cleanup
        c.uv_close(@ptrCast(&wait_data.timeout_timer), null);
        _ = c.uv_run(c.uv_default_loop(), c.UV_RUN_NOWAIT);

        c.lua_pushboolean(state, 1); // true
        c.lua_pushnil(state); // nil (no timeout)
        return 2;
    }

    // Check condition immediately
    c.lua_pushvalue(state, 2); // push condition function
    if (c.lua_pcall(state, 0, 1, 0) != 0) {
        // Error in condition, pop error and continue
        _ = c.lua_pop(state, 1);
    } else {
        const result = c.lua_toboolean(state, -1);
        _ = c.lua_pop(state, 1);
        if (result != 0) {
            c.lua_pushboolean(state, 1); // true
            c.lua_pushnil(state); // nil
            return 2;
        }
    }

    // Store condition in registry
    c.lua_pushvalue(state, 2);
    const condition_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

    // Create wait data on stack (will be valid for the duration of this function)
    var wait_data: WaitData = .{
        .L = state,
        .condition_ref = condition_ref,
        .interval_timer = undefined,
        .timeout_timer = undefined,
        .done = false,
        .success = false,
        .interval = interval,
    };

    // Initialize interval timer
    _ = c.uv_timer_init(c.uv_default_loop(), &wait_data.interval_timer);
    wait_data.interval_timer.data = &wait_data;
    _ = c.uv_timer_start(&wait_data.interval_timer, @ptrCast(&vimWaitIntervalCallback), interval, interval);

    // Initialize timeout timer
    _ = c.uv_timer_init(c.uv_default_loop(), &wait_data.timeout_timer);
    wait_data.timeout_timer.data = &wait_data;
    _ = c.uv_timer_start(&wait_data.timeout_timer, @ptrCast(&vimWaitTimeoutCallback), timeout, 0);

    // Pump event loop until done
    while (!wait_data.done) {
        _ = c.uv_run(c.uv_default_loop(), c.UV_RUN_ONCE);
    }

    // Cleanup timers
    c.uv_close(@ptrCast(&wait_data.interval_timer), null);
    c.uv_close(@ptrCast(&wait_data.timeout_timer), null);
    _ = c.uv_run(c.uv_default_loop(), c.UV_RUN_NOWAIT);

    // Unreference condition
    c.luaL_unref(state, c.LUA_REGISTRYINDEX, condition_ref);

    // Return result
    if (wait_data.success) {
        c.lua_pushboolean(state, 1); // true
        c.lua_pushnil(state); // nil
    } else {
        c.lua_pushboolean(state, 0); // false
        // Neovim returns -1 for timeout, not "timeout" string
        c.lua_pushinteger(state, -1);
    }
    return 2;
}

/// Setup vim.schedule, vim.defer_fn, vim.wait using libuv timers
fn setupVimEventLoop(L: *c.lua_State) !void {
    const eventloop_lua =
        \\vim = vim or {}
        \\
        \\-- Internal queue for scheduled callbacks (FIFO)
        \\local _scheduled_queue = {}
        \\local _scheduled_head = 1
        \\local _scheduled_tail = 0
        \\
        \\-- vim.schedule(fn) - queue callback for next event loop iteration
        \\-- Implemented as a 0ms timer that auto-closes after firing
        \\-- NOTE: Neovim does NOT return a handle from vim.schedule
        \\vim.schedule = function(fn)
        \\  if type(fn) ~= "function" then
        \\    error("vim.schedule: expected function, got " .. type(fn))
        \\  end
        \\  -- Use a 0ms timer to defer execution to next tick
        \\  local timer = vim.uv.new_timer()
        \\  timer:start(0, 0, function()
        \\    fn()
        \\  end)
        \\  -- Neovim does not return the timer handle
        \\end
        \\
        \\-- vim.defer_fn(fn, timeout) - schedule callback after delay
        \\vim.defer_fn = function(fn, timeout)
        \\  if type(fn) ~= "function" then
        \\    error("vim.defer_fn: expected function, got " .. type(fn))
        \\  end
        \\  local timer = vim.uv.new_timer()
        \\  timer:start(timeout or 0, 0, function()
        \\    fn()
        \\  end)
        \\  return timer
        \\end
        \\
        \\-- vim.wait is implemented in C (luaVimWait) and registered below
    ;

    if (c.luaL_dostring(L, eventloop_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.schedule: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }

    // Register vim.wait as C function
    _ = c.lua_getglobal(L, "vim");
    _ = c.lua_pushstring(L, "wait");
    _ = c.lua_pushcfunction(L, @as(c.lua_CFunction, @ptrCast(&luaVimWait)));
    c.lua_settable(L, -3);
    _ = c.lua_pop(L, 1); // pop vim
}

fn setupVimJson(L: *c.lua_State) !void {
    const json_lua =
        \\local function encode(v)
        \\  local t = type(v)
        \\  if t == "string" then return '"' .. v:gsub('[%z\1-\31"\\]', function(c)
        \\    if c == '"' then return '\\"' end; if c == '\\' then return '\\\\' end; if c == '\n' then return '\\n' end
        \\    if c == '\r' then return '\\r' end; if c == '\t' then return '\\t' end
        \\    return string.format('\\u%04x', string.byte(c)) end) .. '"'
        \\  elseif t == "number" then return string.format("%.17g", v)
        \\  elseif t == "boolean" then return v and "true" or "false"
        \\  elseif t == "table" then
        \\    local n = #v; local is_array = true; local count = 0
        \\    for k, _ in pairs(v) do count = count + 1; if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then is_array = false; break end end
        \\    is_array = is_array and (count == n)
        \\    local parts = {}
        \\    if is_array and n > 0 then for i = 1, n do parts[i] = encode(v[i]) end; return "[" .. table.concat(parts, ",") .. "]"
        \\    elseif n == 0 and count == 0 then return "{}"
        \\    else local keys = {}; for k in pairs(v) do table.insert(keys, k) end
        \\      for _, k in ipairs(keys) do table.insert(parts, encode(tostring(k)) .. ":" .. encode(v[k])) end; return "{" .. table.concat(parts, ",") .. "}" end
        \\  else return "null" end
        \\end
        \\local function decode(s)
        \\  local i = 1
        \\  local function skip_ws() while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end end
        \\  local p = {}
        \\  p.parse_string = function()
        \\    i = i + 1; local start = i; local result = {}
        \\    while i <= #s do
        \\      local ch = s:sub(i,i)
        \\      if ch == '\\' then
        \\        table.insert(result, s:sub(start, i-1)); i = i + 1; local esc = s:sub(i,i)
        \\        if esc == '"' then table.insert(result, '"')
        \\        elseif esc == '\\' then table.insert(result, '\\')
        \\        elseif esc == 'n' then table.insert(result, '\n')
        \\        elseif esc == 'r' then table.insert(result, '\r')
        \\        elseif esc == 't' then table.insert(result, '\t')
        \\        elseif esc == '/' then table.insert(result, '/')
        \\        elseif esc == 'u' then local hex = s:sub(i+1, i+4); i = i + 4; local code = tonumber(hex, 16); if code < 128 then table.insert(result, string.char(code)) else table.insert(result, "?") end
        \\        else table.insert(result, esc) end
        \\        i = i + 1; start = i
        \\      elseif ch == '"' then table.insert(result, s:sub(start, i-1)); i = i + 1; return table.concat(result)
        \\      else i = i + 1 end
        \\    end
        \\    return nil
        \\  end
        \\  p.parse_number = function()
        \\    local start = i
        \\    if s:sub(i,i) == '-' then i = i + 1 end
        \\    while i <= #s and s:sub(i,i):match("%d") do i = i + 1 end
        \\    if i <= #s and s:sub(i,i) == '.' then i = i + 1; while i <= #s and s:sub(i,i):match("%d") do i = i + 1 end end
        \\    if i <= #s and (s:sub(i,i) == 'e' or s:sub(i,i) == 'E') then i = i + 1; if i <= #s and (s:sub(i,i) == '+' or s:sub(i,i) == '-') then i = i + 1 end; while i <= #s and s:sub(i,i):match("%d") do i = i + 1 end end
        \\    return tonumber(s:sub(start, i-1))
        \\  end
        \\  p.parse_array = function()
        \\    i = i + 1; local arr = {}; skip_ws()
        \\    if i <= #s and s:sub(i,i) == ']' then i = i + 1; return arr end
        \\    while i <= #s do
        \\      local val = p.parse_value(); table.insert(arr, val); skip_ws()
        \\      if i <= #s and s:sub(i,i) == ']' then i = i + 1; return arr end
        \\      if i <= #s and s:sub(i,i) == ',' then i = i + 1 end
        \\    end
        \\    return arr
        \\  end
        \\  p.parse_object = function()
        \\    i = i + 1; local obj = {}; skip_ws()
        \\    if i <= #s and s:sub(i,i) == '}' then i = i + 1; return obj end
        \\    while i <= #s do
        \\      skip_ws(); local key = p.parse_string(); skip_ws()
        \\      if i <= #s and s:sub(i,i) == ':' then i = i + 1 end
        \\      local val = p.parse_value(); obj[key] = val; skip_ws()
        \\      if i <= #s and s:sub(i,i) == '}' then i = i + 1; return obj end
        \\      if i <= #s and s:sub(i,i) == ',' then i = i + 1 end
        \\    end
        \\    return obj
        \\  end
        \\  p.parse_value = function()
        \\    skip_ws(); if i > #s then return nil end
        \\    local ch = s:sub(i,i)
        \\    if ch == '"' then return p.parse_string()
        \\    elseif ch == '{' then return p.parse_object()
        \\    elseif ch == '[' then return p.parse_array()
        \\    elseif ch == 't' and s:sub(i,i+3) == "true" then i = i + 4; return true
        \\    elseif ch == 'f' and s:sub(i,i+4) == "false" then i = i + 5; return false
        \\    elseif ch == 'n' and s:sub(i,i+3) == "null" then i = i + 4; return nil
        \\    elseif ch == '-' or ch:match("%d") then return p.parse_number()
        \\    end
        \\    return nil
        \\  end
        \\  return p.parse_value()
        \\end
        \\vim = vim or {}; vim.json = { encode = encode, decode = decode }
    ;

    if (c.luaL_dostring(L, json_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.json: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

fn setupVimVersion(L: *c.lua_State) !void {
    const version_lua =
        \\vim = vim or {}
        \\vim.version = function() return { major = 0, minor = 1, patch = 0 } end
    ;
    if (c.luaL_dostring(L, version_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.version: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

fn setupVimFn(L: *c.lua_State) !void {
    const fn_lua =
        \\vim = vim or {}
        \\vim.fn = vim.fn or {}
        \\vim.fn.has = function(feature)
        \\  if feature == "nvim" or feature == "unix" or feature == "mac" or feature == "macunix" then return 1 end
        \\  return 0
        \\end
    ;
    if (c.luaL_dostring(L, fn_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.fn: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

fn setupVimInspect(L: *c.lua_State) !void {
    const inspect_lua =
        \\vim = vim or {}
        \\local ok, inspect = pcall(require, "vim.inspect")
        \\if ok then vim.inspect = inspect end
    ;
    if (c.luaL_dostring(L, inspect_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.inspect: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}

fn setupPackagePath(L: *c.lua_State) !void {
    const setup_path_lua =
        \\package.path = package.path .. ";./runtime/lua/?.lua;./runtime/lua/?/init.lua"
    ;
    if (c.luaL_dostring(L, setup_path_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup package.path: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
}
