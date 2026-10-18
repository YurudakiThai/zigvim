const std = @import("std");
const c = @import("c");
const editor = @import("editor.zig");
const terminal = @import("terminal.zig");
const render = @import("render.zig");

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
    var is_clean: bool = false;
    var i: usize = 1; // skip argv[0]

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            writeAllStdout("zigvim v0.1.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            // no-op for now
        } else if (std.mem.eql(u8, arg, "--clean")) {
            is_clean = true;
        } else if (std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                lua_script = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                i += 1; // skip the command argument (e.g., "qa!")
            }
        }
    }

    if (lua_script) |script_path| {
        try runLuaScript(script_path, gpa, io, arena);
    } else {
        // Editor mode - open file if provided, otherwise start empty
        var filename: ?[]const u8 = null;
        if (i < args.len) {
            filename = args[i];
        }
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

    // 1. package.path for runtime modules
    try setupPackagePath(state);
    // 2. vim.uv mock
    try setupVimUv(state);
    // 3. vim.json (encode + decode)
    try setupVimJson(state);
    // 4. vim.version
    try setupVimVersion(state);
    // 5. vim.fn
    try setupVimFn(state);
    // 6. vim.inspect from runtime
    try setupVimInspect(state);
    // 7. vim.api (buffer/window management)
    try setupVimApi(state);
    // 8. vim.o / vim.opt (options)
    try setupVimOptions(state);
    // 9. vim.g / vim.b / vim.w / vim.t (variables)
    try setupVimVariables(state);
    // 10. vim.schedule / vim.defer_fn / vim.wait (event loop)
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
        \\-- Internal buffer storage: buffers[id] = { lines = {...}, valid = bool, listed = bool, scratch = bool }
        \\local _buffers = {}
        \\local _next_buf_id = 1
        \\local _current_buf = nil
        \\local _current_win = 1000
        \\
        \\-- Autocmd system
        \\local _augroups = {}
        \\local _next_augroup_id = 1
        \\local _autocmds = {}
        \\local _next_autocmd_id = 1
        \\
        \\-- Create initial buffer (buffer 1, the default buffer)
        \\_buffers[1] = { lines = {""}, valid = true, listed = true, scratch = false }
        \\_current_buf = 1
        \\_next_buf_id = 2
        \\
        \\vim.api.nvim_get_current_buf = function()
        \\  return _current_buf
        \\end
        \\
        \\vim.api.nvim_get_current_win = function()
        \\  return _current_win
        \\end
        \\
        \\vim.api.nvim_set_current_buf = function(buf)
        \\  if _buffers[buf] and _buffers[buf].valid then
        \\    _current_buf = buf
        \\  end
        \\end
        \\
        \\vim.api.nvim_create_buf = function(listed, scratch)
        \\  local id = _next_buf_id
        \\  _next_buf_id = _next_buf_id + 1
        \\  _buffers[id] = { lines = {""}, valid = true, listed = listed, scratch = scratch }
        \\  return id
        \\end
        \\
        \\vim.api.nvim_buf_is_valid = function(buf)
        \\  return _buffers[buf] ~= nil and _buffers[buf].valid
        \\end
        \\
        \\vim.api.nvim_buf_line_count = function(buf)
        \\  if _buffers[buf] and _buffers[buf].valid then
        \\    return #_buffers[buf].lines
        \\  end
        \\  return 0
        \\end
        \\
        \\vim.api.nvim_buf_set_lines = function(buf, start, _end, strict_indexing, replacement)
        \\  if not _buffers[buf] or not _buffers[buf].valid then return end
        \\  local lines = _buffers[buf].lines
        \\  local n = #lines
        \\  -- Handle negative indices
        \\  if start < 0 then start = n + start + 1 end
        \\  if _end < 0 then _end = n + _end + 1 end
        \\  -- Convert from 0-based to 1-based
        \\  start = start + 1
        \\  -- _end is exclusive in 0-based, so in 1-based it's the last index to replace
        \\  -- _end in 0-based exclusive means up to but not including _end
        \\  -- In 1-based inclusive, that's _end (since 0-based _end exclusive = 1-based _end inclusive)
        \\  local new_lines = {}
        \\  for i = 1, start - 1 do
        \\    table.insert(new_lines, lines[i])
        \\  end
        \\  for _, line in ipairs(replacement) do
        \\    table.insert(new_lines, line)
        \\  end
        \\  for i = _end + 1, n do
        \\    table.insert(new_lines, lines[i])
        \\  end
        \\  _buffers[buf].lines = new_lines
        \\end
        \\
        \\vim.api.nvim_buf_get_lines = function(buf, start, _end, strict_indexing)
        \\  if not _buffers[buf] or not _buffers[buf].valid then return {} end
        \\  local lines = _buffers[buf].lines
        \\  local n = #lines
        \\  if start < 0 then start = n + start + 1 end
        \\  if _end < 0 then _end = n + _end + 1 end
        \\  start = start + 1
        \\  local result = {}
        \\  for i = start, _end do
        \\    if i >= 1 and i <= n then
        \\      table.insert(result, lines[i])
        \\    end
        \\  end
        \\  return result
        \\end
        \\
        \\vim.api.nvim_buf_delete = function(buf, opts)
        \\  if _buffers[buf] then
        \\    _buffers[buf].valid = false
        \\  end
        \\end
        \\
        \\-- Autocmd system
        \\vim.api.nvim_create_augroup = function(name, opts)
        \\  if opts and opts.clear then
        \\    -- Clear existing autocmds in this group
        \\    for id, ac in pairs(_autocmds) do
        \\      if ac.group == name then
        \\        _autocmds[id] = nil
        \\      end
        \\    end
        \\  end
        \\  _augroups[name] = _next_augroup_id
        \\  _next_augroup_id = _next_augroup_id + 1
        \\  return _augroups[name]
        \\end
        \\
        \\vim.api.nvim_create_autocmd = function(event, opts)
        \\  local id = _next_autocmd_id
        \\  _next_autocmd_id = _next_autocmd_id + 1
        \\  _autocmds[id] = {
        \\    event = event,
        \\    group = opts.group,
        \\    pattern = opts.pattern,
        \\    callback = opts.callback,
        \\  }
        \\  return id
        \\end
        \\
        \\vim.api.nvim_exec_autocmds = function(event, opts)
        \\  local pattern = opts and opts.pattern or "*"
        \\  for id, ac in pairs(_autocmds) do
        \\    local match_event = false
        \\    if type(ac.event) == "table" then
        \\      for _, e in ipairs(ac.event) do
        \\        if e == event then match_event = true; break end
        \\      end
        \\    else
        \\      match_event = (ac.event == event)
        \\    end
        \\    if match_event and ac.pattern == pattern then
        \\      if ac.callback then ac.callback() end
        \\    end
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
        \\local _options = {
        \\  number = false,
        \\  wrap = true,
        \\  tabstop = 8,
        \\  shiftwidth = 8,
        \\  expandtab = false,
        \\  relativenumber = false,
        \\  signcolumn = "auto",
        \\}
        \\
        \\vim.o = setmetatable({}, {
        \\  __index = function(_, key)
        \\    return _options[key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    _options[key] = value
        \\  end,
        \\})
        \\
        \\vim.opt = setmetatable({}, {
        \\  __index = function(_, key)
        \\    return _options[key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    _options[key] = value
        \\  end,
        \\})
        \\
        \\vim.bo = setmetatable({}, {
        \\  __index = function(_, key)
        \\    return _options[key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    _options[key] = value
        \\  end,
        \\})
        \\
        \\vim.wo = setmetatable({}, {
        \\  __index = function(_, key)
        \\    return _options[key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    _options[key] = value
        \\  end,
        \\})
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
        \\
        \\vim.g = setmetatable({}, {
        \\  __index = function(_, key)
        \\    return _global_vars[key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    _global_vars[key] = value
        \\  end,
        \\})
        \\
        \\vim.b = setmetatable({}, {
        \\  __index = function(_, key)
        \\    local buf = vim.api.nvim_get_current_buf()
        \\    _buf_vars[buf] = _buf_vars[buf] or {}
        \\    return _buf_vars[buf][key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    local buf = vim.api.nvim_get_current_buf()
        \\    _buf_vars[buf] = _buf_vars[buf] or {}
        \\    _buf_vars[buf][key] = value
        \\  end,
        \\})
        \\
        \\vim.w = setmetatable({}, {
        \\  __index = function(_, key)
        \\    local win = vim.api.nvim_get_current_win()
        \\    _win_vars[win] = _win_vars[win] or {}
        \\    return _win_vars[win][key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    local win = vim.api.nvim_get_current_win()
        \\    _win_vars[win] = _win_vars[win] or {}
        \\    _win_vars[win][key] = value
        \\  end,
        \\})
        \\
        \\vim.t = setmetatable({}, {
        \\  __index = function(_, key)
        \\    return _tab_vars[key]
        \\  end,
        \\  __newindex = function(_, key, value)
        \\    _tab_vars[key] = value
        \\  end,
        \\})
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
        \\local _scheduled = {}
        \\local _timers = {}
        \\
        \\vim.schedule = function(fn)
        \\  table.insert(_scheduled, fn)
        \\  -- Execute immediately for testing purposes
        \\  fn()
        \\end
        \\
        \\vim.defer_fn = function(fn, timeout)
        \\  -- Execute immediately for testing (real nvim would use a timer)
        \\  fn()
        \\end
        \\
        \\vim.wait = function(timeout, condition, interval)
        \\  if not condition then return true end
        \\  -- Check condition immediately
        \\  if condition() then return true end
        \\  -- For testing, just return false (timeout)
        \\  return false
        \\end
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
        \\  if t == "string" then
        \\    return '"' .. v:gsub('[%z\1-\31"\\]', function(c)
        \\      if c == '"' then return '\\"' end
        \\      if c == '\\' then return '\\\\' end
        \\      if c == '\n' then return '\\n' end
        \\      if c == '\r' then return '\\r' end
        \\      if c == '\t' then return '\\t' end
        \\      return string.format('\\u%04x', string.byte(c))
        \\    end) .. '"'
        \\  elseif t == "number" then
        \\    return string.format("%.17g", v)
        \\  elseif t == "boolean" then
        \\    return v and "true" or "false"
        \\  elseif t == "table" then
        \\    local n = #v
        \\    local is_array = true
        \\    local count = 0
        \\    for k, _ in pairs(v) do
        \\      count = count + 1
        \\      if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
        \\        is_array = false
        \\        break
        \\      end
        \\    end
        \\    is_array = is_array and (count == n)
        \\    local parts = {}
        \\    if is_array and n > 0 then
        \\      for i = 1, n do
        \\        parts[i] = encode(v[i])
        \\      end
        \\      return "[" .. table.concat(parts, ",") .. "]"
        \\    elseif n == 0 and count == 0 then
        \\      return "{}"
        \\    else
        \\      local keys = {}
        \\      for k in pairs(v) do table.insert(keys, k) end
        \\      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        \\      for _, k in ipairs(keys) do
        \\        table.insert(parts, encode(tostring(k)) .. ":" .. encode(v[k]))
        \\      end
        \\      return "{" .. table.concat(parts, ",") .. "}"
        \\    end
        \\  else
        \\    return "null"
        \\  end
        \\end
        \\
        \\local function decode(s)
        \\  local i = 1
        \\  local function skip_ws()
        \\    while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end
        \\  end
        \\  local p = {}
        \\  p.parse_string = function()
        \\    i = i + 1
        \\    local start = i
        \\    local result = {}
        \\    while i <= #s do
        \\      local ch = s:sub(i,i)
        \\      if ch == '\\' then
        \\        table.insert(result, s:sub(start, i-1))
        \\        i = i + 1
        \\        local esc = s:sub(i,i)
        \\        if esc == '"' then table.insert(result, '"')
        \\        elseif esc == '\\' then table.insert(result, '\\')
        \\        elseif esc == 'n' then table.insert(result, '\n')
        \\        elseif esc == 'r' then table.insert(result, '\r')
        \\        elseif esc == 't' then table.insert(result, '\t')
        \\        elseif esc == '/' then table.insert(result, '/')
        \\        elseif esc == 'u' then
        \\          local hex = s:sub(i+1, i+4)
        \\          i = i + 4
        \\          local code = tonumber(hex, 16)
        \\          if code < 128 then
        \\            table.insert(result, string.char(code))
        \\          else
        \\            table.insert(result, "?")
        \\          end
        \\        else table.insert(result, esc) end
        \\        i = i + 1
        \\        start = i
        \\      elseif ch == '"' then
        \\        table.insert(result, s:sub(start, i-1))
        \\        i = i + 1
        \\        return table.concat(result)
        \\      else
        \\        i = i + 1
        \\      end
        \\    end
        \\    return nil
        \\  end
        \\  p.parse_number = function()
        \\    local start = i
        \\    if s:sub(i,i) == '-' then i = i + 1 end
        \\    while i <= #s and s:sub(i,i):match("%d") do i = i + 1 end
        \\    if i <= #s and s:sub(i,i) == '.' then
        \\      i = i + 1
        \\      while i <= #s and s:sub(i,i):match("%d") do i = i + 1 end
        \\    end
        \\    if i <= #s and (s:sub(i,i) == 'e' or s:sub(i,i) == 'E') then
        \\      i = i + 1
        \\      if i <= #s and (s:sub(i,i) == '+' or s:sub(i,i) == '-') then i = i + 1 end
        \\      while i <= #s and s:sub(i,i):match("%d") do i = i + 1 end
        \\    end
        \\    return tonumber(s:sub(start, i-1))
        \\  end
        \\  p.parse_array = function()
        \\    i = i + 1
        \\    local arr = {}
        \\    skip_ws()
        \\    if i <= #s and s:sub(i,i) == ']' then i = i + 1; return arr end
        \\    while i <= #s do
        \\      local val = p.parse_value()
        \\      table.insert(arr, val)
        \\      skip_ws()
        \\      if i <= #s and s:sub(i,i) == ']' then i = i + 1; return arr end
        \\      if i <= #s and s:sub(i,i) == ',' then i = i + 1 end
        \\    end
        \\    return arr
        \\  end
        \\  p.parse_object = function()
        \\    i = i + 1
        \\    local obj = {}
        \\    skip_ws()
        \\    if i <= #s and s:sub(i,i) == '}' then i = i + 1; return obj end
        \\    while i <= #s do
        \\      skip_ws()
        \\      local key = p.parse_string()
        \\      skip_ws()
        \\      if i <= #s and s:sub(i,i) == ':' then i = i + 1 end
        \\      local val = p.parse_value()
        \\      obj[key] = val
        \\      skip_ws()
        \\      if i <= #s and s:sub(i,i) == '}' then i = i + 1; return obj end
        \\      if i <= #s and s:sub(i,i) == ',' then i = i + 1 end
        \\    end
        \\    return obj
        \\  end
        \\  p.parse_value = function()
        \\    skip_ws()
        \\    if i > #s then return nil end
        \\    local ch = s:sub(i,i)
        \\    if ch == '"' then return p.parse_string()
        \\    elseif ch == '{' then return p.parse_object()
        \\    elseif ch == '[' then return p.parse_array()
        \\    elseif ch == 't' then
        \\      if s:sub(i,i+3) == "true" then i = i + 4; return true end
        \\    elseif ch == 'f' then
        \\      if s:sub(i,i+4) == "false" then i = i + 5; return false end
        \\    elseif ch == 'n' then
        \\      if s:sub(i,i+3) == "null" then i = i + 4; return nil end
        \\    elseif ch == '-' or ch:match("%d") then
        \\      return p.parse_number()
        \\    end
        \\    return nil
        \\  end
        \\  return p.parse_value()
        \\end
        \\
        \\vim = vim or {}
        \\vim.json = { encode = encode, decode = decode }
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
        \\vim.version = function()
        \\  return { major = 0, minor = 1, patch = 0 }
        \\end
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
        \\  if feature == "nvim" then return 1 end
        \\  if feature == "unix" then return 1 end
        \\  if feature == "mac" or feature == "macunix" then return 1 end
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
        \\if ok then
        \\  vim.inspect = inspect
        \\end
    ;
    if (c.luaL_dostring(L, inspect_lua)) {
        const err = luaToString(L, -1);
        if (err) |e| {
            std.debug.print("Failed to setup vim.inspect: {s}\n", .{e});
        }
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
        \\  fs_stat = function(path)
        \\    local f = io.open(path, "r")
        \\    if f then f:close(); return { type = "file" } end
        \\    local h = io.popen("test -d '" .. path .. "' && echo dir")
        \\    local is_dir = h:read("*l"); h:close()
        \\    if is_dir == "dir" then return { type = "directory" } end
        \\    return nil
        \\  end,
        \\  fs_lstat = function(path) return vim.uv.fs_stat(path) end,
        \\  fs_realpath = function(path)
        \\    local h = io.popen("realpath '" .. path .. "' 2>/dev/null")
        \\    local r = h:read("*l"); h:close(); return r or path
        \\  end,
        \\  fs_scandir = function(path)
        \\    local h = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
        \\    local files = {}
        \\    for line in h:lines() do table.insert(files, line) end
        \\    h:close()
        \\    local i = 0
        \\    return function()
        \\      i = i + 1
        \\      if i <= #files then return files[i], "file" end
        \\    end
        \\  end,
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
        if (err) |e| {
            std.debug.print("Failed to setup package.path: {s}\n", .{e});
        }
        return error.LuaSetupFailed;
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

fn runEditor(allocator: std.mem.Allocator, io: std.Io, filename: ?[]const u8) !void {
    var term = try terminal.Terminal.init();
    try term.enableRawMode();
    defer term.disableRawMode() catch {};

    var ed = try editor.Editor.init(allocator);
    defer ed.deinit();

    ed.screen_rows = term.screen_rows;
    ed.screen_cols = term.screen_cols;

    if (filename) |fname| {
        ed.openFile(io, fname) catch |err| {
            ed.setStatusMsg("Error: {}", .{err});
        };
    }

    // Main loop
    while (true) {
        render.render(&ed, &term);

        const key = terminal.Terminal.readKey() catch continue;

        switch (key) {
            1000 => ed.moveCursor(.home), // Home
            1001 => ed.moveCursor(.end), // End
            1002 => ed.moveCursor(.page_up), // Page Up
            1003 => ed.moveCursor(.page_down), // Page Down
            1004 => ed.moveCursor(.up), // Up
            1005 => ed.moveCursor(.down), // Down
            1006 => ed.moveCursor(.right), // Right
            1007 => ed.moveCursor(.left), // Left
            13 => try ed.insertNewline(), // Enter
            127 => ed.deleteChar(), // Backspace
            27 => {}, // Escape (ignore for now)
            else => |k| {
                if (k < 32 or k >= 127) continue;
                const ch: u8 = @intCast(k & 0xFF);
                try ed.insertChar(ch);
            },
        }

        ed.scroll();
    }
}
