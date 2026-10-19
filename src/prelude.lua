-- zigvim Lua compatibility layer.
-- Loaded once after the C-level `vim` table is registered, before user code.

-- Make Neovim's shipped runtime modules available (vim.inspect, vim.iter, ...).
package.path = "runtime/lua/?.lua;runtime/lua/?/init.lua;" .. package.path

-- ---------------------------------------------------------------- vim.json
local json = {}

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function json_escape(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
  end))
end

local function is_array(t)
  local n = #t
  if n == 0 then
    -- Empty tables encode as objects, matching Neovim's vim.json behaviour.
    return false
  end
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  return count == n
end

local encode_value

function encode_value(v)
  local t = type(v)
  if t == 'nil' then
    return 'null'
  elseif t == 'boolean' then
    return v and 'true' or 'false'
  elseif t == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then
      error('Cannot serialise number: ' .. tostring(v))
    end
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format('%d', v)
    end
    -- Shortest round-trip representation (LuaJIT's tostring uses %.14g).
    for precision = 1, 17 do
      local s = string.format('%.' .. precision .. 'g', v)
      if tonumber(s) == v then
        return s
      end
    end
    return string.format('%.17g', v)
  elseif t == 'string' then
    return '"' .. json_escape(v) .. '"'
  elseif t == 'table' then
    local parts = {}
    if is_array(v) then
      for i = 1, #v do
        parts[i] = encode_value(v[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, val in pairs(v) do
      if type(k) ~= 'string' then
        k = tostring(k)
      end
      parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. encode_value(val)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('Cannot serialise ' .. t)
end

function json.encode(v)
  return encode_value(v)
end

local function skip_ws(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
      i = i + 1
    else
      break
    end
  end
  return i
end

local decode_value

local function decode_string(s, i)
  -- s:sub(i,i) == '"'
  local out = {}
  i = i + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == '\\' then
      i = i + 1
      local e = s:sub(i, i)
      if e == '"' or e == '\\' or e == '/' then
        out[#out + 1] = e
      elseif e == 'b' then
        out[#out + 1] = '\b'
      elseif e == 'f' then
        out[#out + 1] = '\f'
      elseif e == 'n' then
        out[#out + 1] = '\n'
      elseif e == 'r' then
        out[#out + 1] = '\r'
      elseif e == 't' then
        out[#out + 1] = '\t'
      elseif e == 'u' then
        local hex = s:sub(i + 1, i + 4)
        local cp = tonumber(hex, 16)
        if not cp then
          error('invalid unicode escape')
        end
        i = i + 4
        if cp >= 0xD800 and cp <= 0xDBFF then
          -- surrogate pair
          if s:sub(i + 1, i + 2) == '\\u' then
            local lo = tonumber(s:sub(i + 3, i + 6), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              i = i + 6
            end
          end
        end
        if cp < 0x80 then
          out[#out + 1] = string.char(cp)
        elseif cp < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        elseif cp < 0x10000 then
          out[#out + 1] = string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40
          )
        else
          out[#out + 1] = string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40
          )
        end
      else
        error('invalid escape')
      end
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  error('unterminated string')
end

function decode_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '' then
    error('unexpected end of input')
  elseif c == '"' then
    return decode_string(s, i)
  elseif c == '{' then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then
      return obj, i + 1
    end
    while true do
      local key
      key, i = decode_string(s, skip_ws(s, i))
      i = skip_ws(s, i)
      if s:sub(i, i) ~= ':' then
        error('expected :')
      end
      local val
      val, i = decode_value(s, i + 1)
      obj[key] = val
      i = skip_ws(s, i)
      local sep = s:sub(i, i)
      if sep == '}' then
        return obj, i + 1
      elseif sep ~= ',' then
        error('expected , or }')
      end
      i = i + 1
    end
  elseif c == '[' then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then
      return arr, i + 1
    end
    while true do
      local val
      val, i = decode_value(s, i)
      arr[#arr + 1] = val
      i = skip_ws(s, i)
      local sep = s:sub(i, i)
      if sep == ']' then
        return arr, i + 1
      elseif sep ~= ',' then
        error('expected , or ]')
      end
      i = i + 1
    end
  elseif s:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then
    return nil, i + 4
  else
    local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if not num or num == '' then
      error('unexpected character: ' .. c)
    end
    return tonumber(num), i + #num
  end
end

function json.decode(s)
  local val, i = decode_value(s, 1)
  i = skip_ws(s, i)
  if i <= #s then
    error('trailing characters')
  end
  return val
end

vim.json = json

-- ------------------------------------------------------------- vim.version
vim.version = function()
  return { major = 0, minor = 1, patch = 0 }
end

-- ------------------------------------------------------------- vim.inspect
do
  local ok, insp = pcall(require, 'vim.inspect')
  if ok then
    vim.inspect = insp
  else
    vim.inspect = function(v)
      if type(v) ~= 'table' then
        return tostring(v)
      end
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = tostring(k) .. ' = ' .. tostring(val)
      end
      return '{ ' .. table.concat(parts, ', ') .. ' }'
    end
  end
end

-- --------------------------------------------------------------- options
local option_defaults = {
  number = false,
  wrap = true,
  tabstop = 8,
  shiftwidth = 8,
  softtabstop = 0,
  expandtab = false,
  autoindent = false,
  smartindent = false,
  ignorecase = false,
  smartcase = false,
  hlsearch = false,
  incsearch = false,
  ruler = false,
  showmode = false,
  laststatus = 2,
  cmdheight = 1,
  background = 'light',
  filetype = '',
  syntax = '',
  buftype = '',
  buflisted = true,
  readonly = false,
  modified = false,
  termguicolors = false,
  mouse = '',
  clipboard = '',
}

local option_store = {}
local option_mt = {
  __index = function(_, k)
    local v = option_store[k]
    if v ~= nil then
      return v
    end
    return option_defaults[k]
  end,
  __newindex = function(_, k, v)
    option_store[k] = v
  end,
}

vim.o = setmetatable({}, option_mt)
vim.opt = setmetatable({}, option_mt)
vim.opt_local = vim.opt
vim.opt_global = vim.opt

-- Buffer-local options. `modified` is authoritative in the Zig core; the
-- rest live in this Lua table until the option registry moves down.
local buffer_options = {}

local function buf_opt_get(id, k)
  if k == 'modified' then
    return vim._buf_modified(id)
  end
  local opts = buffer_options[id]
  if opts and opts[k] ~= nil then
    return opts[k]
  end
  return option_defaults[k]
end

local function buf_opt_set(id, k, v)
  if k == 'modified' then
    vim._buf_set_modified(id, v)
    return
  end
  local opts = buffer_options[id]
  if not opts then
    opts = {}
    buffer_options[id] = opts
  end
  opts[k] = v
end

local function make_bo(id)
  return setmetatable({}, {
    __index = function(_, k)
      return buf_opt_get(id, k)
    end,
    __newindex = function(_, k, v)
      buf_opt_set(id, k, v)
    end,
  })
end

vim.bo = setmetatable({}, {
  __index = function(_, k)
    if type(k) == 'number' then
      return make_bo(k == 0 and vim.api.nvim_get_current_buf() or k)
    end
    return buf_opt_get(vim.api.nvim_get_current_buf(), k)
  end,
  __newindex = function(_, k, v)
    buf_opt_set(vim.api.nvim_get_current_buf(), k, v)
  end,
})

-- Window-local options (a single window for now).
local window_options = {}
vim.wo = setmetatable({}, {
  __index = function(_, k)
    local v = window_options[k]
    if v ~= nil then
      return v
    end
    return option_defaults[k]
  end,
  __newindex = function(_, k, v)
    window_options[k] = v
  end,
})

-- ------------------------------------------------------------- variables
vim.g = setmetatable({}, {
  __index = function() end,
  __newindex = function(t, k, v)
    rawset(t, k, v)
  end,
})

local buffer_vars = {}
vim.b = setmetatable({}, {
  __index = function(_, k)
    local vars = buffer_vars[vim.api.nvim_get_current_buf()]
    return vars and vars[k]
  end,
  __newindex = function(_, k, v)
    local id = vim.api.nvim_get_current_buf()
    local vars = buffer_vars[id]
    if not vars then
      vars = {}
      buffer_vars[id] = vars
    end
    vars[k] = v
  end,
})

vim.w = {}
vim.t = {}
vim.v = {}

-- ------------------------------------------------------------- autocmds
local augroups = {}
local autocmds = {}
local next_autocmd_id = 0

local function event_list(event)
  if type(event) == 'table' then
    return event
  end
  return { event }
end

function vim.api.nvim_create_augroup(name, _)
  augroups[name] = true
  return name
end

function vim.api.nvim_create_autocmd(event, opts)
  next_autocmd_id = next_autocmd_id + 1
  autocmds[#autocmds + 1] = {
    id = next_autocmd_id,
    events = event_list(event),
    pattern = opts and opts.pattern,
    callback = opts and opts.callback,
    group = opts and opts.group,
    once = opts and opts.once,
  }
  return next_autocmd_id
end

function vim.api.nvim_exec_autocmds(event, opts)
  local pattern = opts and opts.pattern
  for _, ac in ipairs(autocmds) do
    local matches = false
    for _, e in ipairs(ac.events) do
      if e == event then
        matches = true
        break
      end
    end
    if matches then
      if not ac.pattern or not pattern or ac.pattern == pattern then
        if ac.callback then
          ac.callback({ event = event, match = pattern, id = ac.id })
        end
      end
    end
  end
end

function vim.api.nvim_clear_autocmds(_)
  autocmds = {}
end

-- ------------------------------------------------------------ defer_fn
-- Implemented in Lua on top of the real libuv timer handles.
function vim.defer_fn(fn, ms)
  local timer = vim.uv.new_timer()
  timer:start(ms, 0, function()
    timer:stop()
    timer:close()
    fn()
  end)
  return timer
end

-- --------------------------------------------------------------- vim.fn
local function home_dir()
  return os.getenv('HOME') or os.getenv('USERPROFILE') or '/'
end

local function xdg(kind, fallback)
  local env = os.getenv(kind)
  if env and env ~= '' then
    return env
  end
  return home_dir() .. fallback
end

function vim.fn.stdpath(what)
  if what == 'config' then
    return xdg('XDG_CONFIG_HOME', '/.config') .. '/zigvim'
  elseif what == 'data' then
    return xdg('XDG_DATA_HOME', '/.local/share') .. '/zigvim'
  elseif what == 'state' then
    return xdg('XDG_STATE_HOME', '/.local/state') .. '/zigvim'
  elseif what == 'cache' then
    return xdg('XDG_CACHE_HOME', '/.cache') .. '/zigvim'
  elseif what == 'log' then
    return xdg('XDG_STATE_HOME', '/.local/state') .. '/zigvim/log'
  end
  return ''
end

function vim.fn.getcwd()
  return vim.uv.cwd()
end

local function basename(path)
  return (path:gsub('/+$', ''):match('([^/]+)$')) or path
end

local function dirname(path)
  local dir = path:match('^(.*)/[^/]*$')
  if dir == '' then
    return '/'
  end
  return dir or '.'
end

function vim.fn.fnamemodify(path, modifiers)
  path = tostring(path)
  for mod in tostring(modifiers):gmatch(':([^:]+)') do
    if mod == 'p' then
      if path:sub(1, 1) ~= '/' then
        path = vim.uv.cwd() .. '/' .. path
      end
    elseif mod == 'h' then
      path = dirname(path)
    elseif mod == 't' then
      path = basename(path)
    elseif mod == 'r' then
      path = path:gsub('%.[^./]+$', '')
    elseif mod == 'e' then
      path = path:match('%.([^./]+)$') or ''
    end
  end
  return path
end

function vim.fn.expand(expr)
  expr = tostring(expr)
  local name = vim._buf_short_name(0)
  if name == '' then
    name = vim.api.nvim_buf_get_name(0)
  end
  if expr == '%' then
    return name
  elseif expr == '%:p' then
    return vim.fn.fnamemodify(name, ':p')
  elseif expr == '%:t' then
    return basename(name)
  elseif expr == '~' then
    return home_dir()
  elseif expr:sub(1, 1) == '~' then
    return home_dir() .. expr:sub(2)
  end
  return expr
end

function vim.fn.filereadable(path)
  local f = io.open(path, 'r')
  if f then
    f:close()
    return 1
  end
  return 0
end

function vim.fn.getenv(name)
  local value = os.getenv(name)
  if value == nil then
    return vim.NIL
  end
  return value
end

function vim.fn.exists(expr)
  if expr == '*vim' or expr == 'g:zigvim' then
    return 1
  end
  return 0
end

-- ------------------------------------------------------------- vim.cmd
local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local data = f:read('*a') or ''
  f:close()
  local lines = {}
  for line in data:gmatch('([^\n]*)\n') do
    lines[#lines + 1] = line:gsub('\r$', '')
  end
  if data ~= '' and data:sub(-1) ~= '\n' then
    lines[#lines + 1] = data:match('([^\n]*)$'):gsub('\r$', '')
  end
  if #lines == 0 then
    lines = { '' }
  end
  return lines
end

local function write_file(path, lines)
  local f = io.open(path, 'wb')
  if not f then
    error('E212: Can\'t open file for writing: ' .. path)
  end
  local body
  if #lines == 1 and lines[1] == '' then
    body = ''
  else
    body = table.concat(lines, '\n') .. '\n'
  end
  f:write(body)
  f:close()
end

local function edit_path(path)
  local full = vim.fn.fnamemodify(path, ':p')
  local lines = read_file(full)
  vim.api.nvim_buf_set_name(0, path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or { '' })
  vim._buf_set_modified(0, false)
end

local function write_current(path)
  local target
  if path and path ~= '' then
    vim.api.nvim_buf_set_name(0, path)
    target = vim.fn.fnamemodify(path, ':p')
  else
    target = vim.api.nvim_buf_get_name(0)
  end
  if target == '' then
    error('E32: No file name')
  end
  write_file(target, buffer_lines())
  vim._buf_set_modified(0, false)
end

local function parse_set(arg)
  if arg:sub(1, 3) == 'no' then
    vim.o[arg:sub(3)] = false
    return
  end
  local name, value = arg:match('^([^=]+)=(.*)$')
  if name then
    local num = tonumber(value)
    if num then
      vim.o[name] = num
    elseif value == 'true' or value == 'false' then
      vim.o[name] = value == 'true'
    else
      vim.o[name] = value
    end
    return
  end
  vim.o[arg] = true
end

local function exec_cmd(cmd)
  cmd = cmd:gsub('^%s*:?%s*', ''):gsub('%s+$', '')
  if cmd == '' or cmd:sub(1, 1) == '"' then
    return
  end

  local name, rest = cmd:match('^(%S+)%s*(.*)$')
  rest = rest or ''

  if name == 'silent' or name == 'silent!' then
    exec_cmd(rest)
  elseif name == 'edit' or name == 'e' then
    local path = rest ~= '' and rest or vim.api.nvim_buf_get_name(0)
    if path == '' then
      error('E32: No file name')
    end
    edit_path(path)
  elseif name == 'write' or name == 'w' then
    write_current(rest)
  elseif name == 'wq' or name == 'x' or name == 'xit' then
    if rest ~= '' then
      write_current(rest)
    elseif vim.bo.modified then
      write_current('')
    end
  elseif name == 'q' or name == 'quit' or name == 'qa' or name == 'qall' or name == 'q!' or name == 'qa!' or name == 'qall!' then
    -- Nothing to do: the caller decides when to stop.
  elseif name == 'enew' then
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
  elseif name == 'set' then
    for option in rest:gmatch('%S+') do
      parse_set(option)
    end
  elseif name == 'setlocal' then
    for option in rest:gmatch('%S+') do
      local key, value = option:match('^([^=]+)=(.*)$')
      if key then
        vim.bo[key] = tonumber(value) or value
      else
        vim.bo[option] = true
      end
    end
  elseif name == 'lua' then
    local chunk, err = loadstring(rest)
    if not chunk then
      error(err)
    end
    chunk()
  elseif name == 'let' then
    local var, expr = rest:match('^(.-)%s*=%s*(.*)$')
    if var == 'g:' or var:sub(1, 2) ~= 'g:' then
      error('E121: Undefined variable: ' .. tostring(var))
    end
    local chunk, err = loadstring('return ' .. expr)
    if not chunk then
      error(err)
    end
    vim.g[var:sub(3)] = chunk()
  elseif name == 'echo' then
    local chunk, err = loadstring('return ' .. rest)
    if not chunk then
      error(err)
    end
    local value = chunk()
    io.stdout:write(tostring(value) .. '\n')
  else
    error('E492: Not an editor command: ' .. cmd)
  end
end

function vim.cmd(cmd)
  if type(cmd) == 'table' then
    cmd = cmd.cmd or cmd[1]
  end
  for line in tostring(cmd):gmatch('[^\n]+') do
    exec_cmd(line)
  end
end

local function exec_lua(code, args)
  local chunk, err = loadstring(code)
  if not chunk then
    error(err)
  end
  return chunk(unpack(args or {}))
end

vim.api.nvim_command = function(cmd)
  vim.cmd(cmd)
end

vim.api.nvim_exec2 = function(src, _)
  vim.cmd(src)
  return { output = '' }
end

vim.api.nvim_exec_lua = function(code, args)
  return exec_lua(code, args)
end

vim.api.nvim_buf_is_loaded = function(buf)
  return vim.api.nvim_buf_is_valid(buf)
end

vim.api.nvim_buf_call = function(buf, fn)
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(buf)
  local ok, result = pcall(fn)
  vim.api.nvim_set_current_buf(prev)
  if not ok then
    error(result)
  end
  return result
end

-- Load the user's init.lua when running as an editor (not for -l scripts).
function vim._load_init()
  local path = vim.fn.stdpath('config') .. '/init.lua'
  local f = io.open(path, 'r')
  if not f then
    return false
  end
  f:close()
  local ok, err = pcall(dofile, path)
  if not ok then
    io.stderr:write('Error in init.lua: ' .. tostring(err) .. '\n')
  end
  return true
end
