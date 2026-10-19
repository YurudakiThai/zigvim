const std = @import("std");
const c = @import("c");
const editor = @import("editor.zig");
const terminal = @import("terminal.zig");
const render = @import("render.zig");

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
    var i: usize = 1; // skip argv[0]
    var filename: ?[]const u8 = null;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("zigvim v0.1.0\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            // no-op
        } else if (std.mem.eql(u8, arg, "--clean")) {
            // no-op
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
            filename = arg;
            break;
        }
    }

    if (lua_script) |script_path| {
        try runLuaScript(script_path, gpa, io, arena);
    } else {
        try runEditor(gpa, io, filename);
    }
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

fn setupVimEventLoop(L: *c.lua_State) !void {
    const eventloop_lua =
        \\vim = vim or {}
        \\vim.schedule = function(fn) table.insert({}, fn); fn() end
        \\vim.defer_fn = function(fn, timeout) fn() end
        \\vim.wait = function(timeout, condition, interval) if not condition then return true end; if condition() then return true end; return false end
    ;

    if (c.luaL_dostring(L, eventloop_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.schedule: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
    }
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
        \\    else local keys = {}; for k in pairs(v) do table.insert(keys, k) end; table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
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
        if (err) |e| { std.debug.print("Failed to setup vim.version: {s}\n", .{e}); }
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
        if (err) |e| { std.debug.print("Failed to setup vim.fn: {s}\n", .{e}); }
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
        if (err) |e| { std.debug.print("Failed to setup vim.inspect: {s}\n", .{e}); }
        return error.LuaSetupFailed;
    }
}

fn setupVimUv(L: *c.lua_State) !void {
    const uv_mock_lua =
        \\vim = vim or {}
        \\vim.uv = {
        \\  os_uname = function() return { sysname = "Darwin" } end,
        \\  cwd = function() return os.getenv("PWD") or "." end,
        \\  os_homedir = function() return os.getenv("HOME") or "/tmp" end,
        \\  os_getenv = function(name) return os.getenv(name) end,
        \\  fs_stat = function(path) local f = io.open(path, "r"); if f then f:close(); return { type = "file" } end; local h = io.popen("test -d '" .. path .. "' && echo dir"); local is_dir = h:read("*l"); h:close(); if is_dir == "dir" then return { type = "directory" } end; return nil end,
        \\  fs_lstat = function(path) return vim.uv.fs_stat(path) end,
        \\  fs_realpath = function(path) local h = io.popen("realpath '" .. path .. "' 2>/dev/null"); local r = h:read("*l"); h:close(); return r or path end,
        \\  fs_scandir = function(path) local h = io.popen("ls -1 '" .. path .. "' 2>/dev/null"); local files = {}; for line in h:lines() do table.insert(files, line) end; h:close(); local i = 0; return function() i = i + 1; if i <= #files then return files[i], "file" end end end,
        \\  fs_scandir_next = function(req) return req() end,
        \\  fs_rmdir = function(path) os.execute("rmdir '" .. path .. "'"); return true end,
        \\  fs_unlink = function(path) os.execute("rm '" .. path .. "'"); return true end,
        \\}
    ;

    if (c.luaL_dostring(L, uv_mock_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.uv: {s}\n", .{e});
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
        if (err) |e| { std.debug.print("Failed to setup package.path: {s}\n", .{e}); }
        return error.LuaSetupFailed;
    }
}

fn runEditor(gpa: std.mem.Allocator, io: std.Io, filename: ?[]const u8) !void {
    var term = try terminal.Terminal.init();
    try term.enableRawMode();
    defer term.disableRawMode() catch {};

    var ed = try editor.Editor.init(gpa);
    defer ed.deinit();

    ed.screen_rows = term.screen_rows;
    ed.screen_cols = term.screen_cols;

    if (filename) |fname| {
        ed.openFile(io, fname) catch |err| {
            ed.setStatusMsg("Error: {}", .{err});
        };
    } else {
        ed.setStatusMsg("zigvim - Ctrl+Q: quit | i: insert | :w to save", .{});
    }

    while (!ed.should_quit) {
        render.render(&ed, &term);

        const key = term.readKey() catch 0;
        if (key == 0) continue;

        switch (ed.mode) {
            .normal => {
                switch (key) {
                    1000 => ed.moveCursor(.home),
                    1001 => ed.moveCursor(.end),
                    1002 => ed.moveCursor(.page_up),
                    1003 => ed.moveCursor(.page_down),
                    1004 => ed.moveCursor(.up),
                    1005 => ed.moveCursor(.down),
                    1006 => ed.moveCursor(.right),
                    1007 => ed.moveCursor(.left),
                    17 => ed.should_quit = true,
                    19 => ed.saveFile(io) catch {},
                    else => |k| {
                        if (k >= 32 and k < 127) {
                            const ch: u8 = @intCast(k & 0xFF);
                            ed.handleNormalKey(ch) catch {};
                        }
                    },
                }
            },
            .insert => {
                switch (key) {
                    27 => { ed.mode = .normal; ed.clearStatusMsg(); },
                    1000 => ed.moveCursor(.home),
                    1001 => ed.moveCursor(.end),
                    1002 => ed.moveCursor(.page_up),
                    1003 => ed.moveCursor(.page_down),
                    1004 => ed.moveCursor(.up),
                    1005 => ed.moveCursor(.down),
                    1006 => ed.moveCursor(.right),
                    1007 => ed.moveCursor(.left),
                    17 => ed.should_quit = true,
                    19 => ed.saveFile(io) catch {},
                    13 => ed.insertNewline() catch {},
                    127 => ed.deleteChar(),
                    8 => ed.deleteChar(),
                    else => |k| {
                        if (k >= 32 and k < 127) {
                            const ch: u8 = @intCast(k & 0xFF);
                            ed.insertChar(ch) catch {};
                        }
                    },
                }
            },
            .command => {
                debugLogMain("command mode: key={}", .{key});
                switch (key) {
                    27 => { 
                        ed.mode = .normal; 
                        ed.cmd_buf.clearRetainingCapacity(); 
                        ed.clearStatusMsg(); 
                    },
                    1000 => ed.moveCursor(.home),
                    1001 => ed.moveCursor(.end),
                    1002 => ed.moveCursor(.page_up),
                    1003 => ed.moveCursor(.page_down),
                    1004 => ed.moveCursor(.up),
                    1005 => ed.moveCursor(.down),
                    1006 => ed.moveCursor(.right),
                    1007 => ed.moveCursor(.left),
                    17 => ed.should_quit = true,
                    19 => ed.saveFile(io) catch {},
                    127 => { 
                        // Backspace in command mode
                        if (ed.cmd_buf.items.len > 0) {
                            _ = ed.cmd_buf.pop();
                        } else {
                            // If command buffer is empty, exit command mode
                            ed.mode = .normal;
                            ed.clearStatusMsg();
                        }
                    },
                    8 => { 
                        // Ctrl+H (also backspace)
                        if (ed.cmd_buf.items.len > 0) {
                            _ = ed.cmd_buf.pop();
                        } else {
                            ed.mode = .normal;
                            ed.clearStatusMsg();
                        }
                    },
                    13 => {
                        // Enter - execute command
                        const result = ed.executeCommand();
                        switch (result) {
                            editor.CommandResult.save => ed.saveFile(io) catch {},
                            editor.CommandResult.quit => {
                                if (ed.dirty) {
                                    ed.setStatusMsg("E37: No write since last change (add ! to override)", .{});
                                } else {
                                    ed.should_quit = true;
                                }
                            },
                            editor.CommandResult.save_and_quit => { 
                                ed.saveFile(io) catch {}; 
                                ed.should_quit = true; 
                            },
                            editor.CommandResult.force_quit => ed.should_quit = true,
                            editor.CommandResult.cmd_error => {},
                            editor.CommandResult.none => {},
                        }
                    },
                    else => |k| {
                        debugLogMain("  command else: k={}, range check: {}", .{ k, k >= 32 and k < 127 });
                        if (k >= 32 and k < 127) {
                            const ch: u8 = @intCast(k & 0xFF);
                            ed.cmd_buf.append(ed.allocator, ch) catch |err| {
                                debugLogMain("  APPEND FAILED: {}", .{err});
                            };
                            debugLogMain("  appended '{}', cmd_buf.len={}, cmd_buf=\"{s}\"", .{ ch, ed.cmd_buf.items.len, ed.cmd_buf.items });
                        } else {
                            debugLogMain("  key out of range, NOT appending", .{});
                        }
                    },
                }
            },
        }

        ed.scroll();
    }

    terminal.Terminal.clearScreen();
    terminal.Terminal.showCursor();
}