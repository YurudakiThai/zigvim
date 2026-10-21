-- zigvim Lua compatibility layer.
-- Loaded once after the C-level `vim` table is registered, before user code.

-- Make Neovim's shipped runtime modules available (vim.inspect, vim.iter, ...).
-- ZIGVIM_RUNTIME overrides the location (default: ./runtime, i.e. run zigvim
-- from the project root or point the variable at <project>/runtime).
local runtime_dir = os.getenv('ZIGVIM_RUNTIME')
if runtime_dir == nil or runtime_dir == '' then
  runtime_dir = 'runtime'
  -- Prefer <project>/runtime next to the binary (<project>/zig-out/bin/zigvim)
  -- so zigvim works from any working directory.
  local exe = vim.uv.exepath and vim.uv.exepath()
  local root = exe and exe:match('^(.*)/zig%-out/bin/[^/]+$')
  if root then
    local probe = io.open(root .. '/runtime/lua/vim/inspect.lua', 'r')
    if probe then
      probe:close()
      runtime_dir = root .. '/runtime'
    end
  end
end
package.path = runtime_dir .. '/lua/?.lua;' .. runtime_dir .. '/lua/?/init.lua;' .. package.path

-- Neovim raises API errors without a Lua source position prefix (the message
-- comes from the C API layer). Use level 0 so pcall() sees the same text.
local function api_error(msg)
  error(msg, 0)
end

-- Neovim's own shared library provides vim.tbl_*, vim.list_*, vim.split,
-- vim.trim, vim.deep_equal and friends. Prefer it over reimplementing them.
if type(vim.NIL) == 'nil' then
  vim.NIL = {}
end
local ok_shared = pcall(require, 'vim._core.shared')
if ok_shared then
  local ok_inspect, inspect = pcall(require, 'vim.inspect')
  if ok_inspect then
    vim.inspect = inspect
  end
end

if vim.stricmp == nil then
  -- Case-insensitive comparison with C strcmp-style -1/0/1 results.
  function vim.stricmp(a, b)
    local la, lb = tostring(a):lower(), tostring(b):lower()
    if la == lb then
      return 0
    end
    return la < lb and -1 or 1
  end
end

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

vim._empty_dict_mt = vim._empty_dict_mt or {}
vim.empty_dict = function()
  return setmetatable({}, vim._empty_dict_mt)
end

local function is_array(t)
  local n = #t
  if n == 0 then
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
  if vim.NIL ~= nil and v == vim.NIL then
    return 'null'
  end
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
    if vim._empty_dict_mt and getmetatable(v) == vim._empty_dict_mt then
      return '{}'
    end
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
    return vim.NIL, i + 4
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

-- ---------------------------------------------------------- vim.log/notify
vim.log = vim.log or {}
vim.log.levels = {
  TRACE = 0,
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  OFF = 5,
}

local notified_once = {}

-- Deprecated APIs call this; keep the warning once per name and report as
-- Neovim does (true means the deprecated path was taken).
vim._deprecation_warned = vim._deprecation_warned or {}
function vim.deprecate(name, alternative, version, plugin, backtrace)
  local key = tostring(name)
  if not vim._deprecation_warned[key] then
    vim._deprecation_warned[key] = true
    local msg = name .. ' is deprecated'
    if alternative and alternative ~= '' then
      msg = msg .. '. Use ' .. alternative .. ' instead'
    end
    if version and version ~= '' then
      msg = msg .. '. Feature will be removed in version ' .. tostring(version)
    end
    io.stderr:write(msg .. '\n')
  end
  return true
end

function vim.notify(msg, level, opts)
  level = level or vim.log.levels.INFO
  local prefix = ({
    [vim.log.levels.TRACE] = 'TRACE',
    [vim.log.levels.DEBUG] = 'DEBUG',
    [vim.log.levels.INFO] = 'INFO',
    [vim.log.levels.WARN] = 'WARN',
    [vim.log.levels.ERROR] = 'ERROR',
  })[level]
  io.stderr:write((prefix and (prefix .. ': ') or '') .. tostring(msg) .. '\n')
  return nil
end

function vim.notify_once(msg, level, opts)
  local key = tostring(msg)
  if notified_once[key] then
    return nil
  end
  notified_once[key] = true
  return vim.notify(msg, level, opts)
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
  autoindent = true,
  smartindent = false,
  ignorecase = false,
  smartcase = false,
  hlsearch = true,
  incsearch = true,
  ruler = true,
  showmode = true,
  laststatus = 2,
  cmdheight = 1,
  background = 'dark',
  filetype = '',
  syntax = '',
  buftype = '',
  buflisted = true,
  readonly = false,
  modified = false,
  termguicolors = false,
  mouse = 'nvi',
  clipboard = '',
  loadplugins = true,
}

-- Short names (sw, rnu, ...) resolve to their long option through the
-- metatable, so every table keyed by option name accepts both spellings.
local option_aliases = {}
local function alias_table(t)
  return setmetatable(t, {
    __index = function(tbl, k)
      local long = option_aliases[k]
      if long then
        return rawget(tbl, long)
      end
    end,
    __newindex = function(tbl, k, v)
      rawset(tbl, option_aliases[k] or k, v)
    end,
  })
end

alias_table(option_defaults)
local option_store = alias_table({})
-- Per-buffer values of buffer-local options, and which options are buffer-local.
local buffer_options = {}
local buffer_local = {}

-- Neovim's generated option metadata lists every option with its default and
-- short name, so use it instead of keeping a hand-written subset.
do
  local f = io.open(runtime_dir .. '/lua/vim/_meta/options.gen.lua', 'r')
  if f then
    local text = f:read('*a') or ''
    f:close()
    for name in text:gmatch('\nvim%.bo%.([%w_]+) = vim%.o%.[%w_]+') do
      buffer_local[name] = true
    end
    for name, rhs in text:gmatch('\nvim%.o%.([%w_]+) = ([^\n]+)') do
      local target = rhs:match('^vim%.o%.([%w_]+)$')
      if target then
        option_aliases[name] = target
      elseif rawget(option_defaults, name) == nil then
        local chunk = loadstring('return ' .. rhs)
        if chunk then
          local ok, value = pcall(chunk)
          if ok and value ~= nil then
            rawset(option_defaults, name, value)
          end
        end
      end
    end
  end
end

local function check_option(name)
  if name == nil or option_defaults[name] == nil then
    api_error("Unknown option '" .. tostring(name) .. "'")
  end
end

local function check_buf_option(name)
  if name == nil or option_defaults[name] == nil then
    api_error("Invalid option name: '" .. tostring(name) .. "'")
  end
end

local option_mt = {
  __index = function(_, k)
    check_option(k)
    if buffer_local[option_aliases[k] or k] then
      local opts = buffer_options[vim.api.nvim_get_current_buf()]
      local local_value = opts and opts[k]
      if local_value ~= nil then
        return local_value
      end
    end
    local v = option_store[k]
    if v ~= nil then
      return v
    end
    return option_defaults[k]
  end,
  -- Like `:set`: sets the global value and, for buffer-local options, the
  -- current buffer's value too.
  __newindex = function(_, k, v)
    check_option(k)
    option_store[k] = v
    if buffer_local[option_aliases[k] or k] then
      local id = vim.api.nvim_get_current_buf()
      local opts = buffer_options[id]
      if not opts then
        opts = alias_table({})
        buffer_options[id] = opts
      end
      opts[k] = v
    end
  end,
}

-- ------------------------------------------------- list options (rtp, pp)
-- 'runtimepath' and 'packpath' are comma lists that plugin managers mutate
-- with vim.opt.rtp:prepend()/append()/remove(). `require` resolves Lua
-- modules through 'runtimepath' (<dir>/lua/<name>.lua), like Neovim does.
local list_option_aliases = {
  runtimepath = 'runtimepath',
  rtp = 'runtimepath',
  packpath = 'packpath',
  pp = 'packpath',
}
local list_option_store = {}

local function runtime_root()
  if runtime_dir:sub(1, 1) == '/' then
    return runtime_dir
  end
  return (vim.uv.cwd() or '.') .. '/' .. runtime_dir
end

local function list_get(name)
  local list = list_option_store[name]
  if not list then
    local config = vim.fn.stdpath('config')
    local data = vim.fn.stdpath('data')
    if name == 'runtimepath' then
      list = { config, data .. '/site', runtime_root(), data .. '/site/after', config .. '/after' }
    else
      list = { data .. '/site' }
    end
    list_option_store[name] = list
  end
  return list
end

local function to_list(value)
  local out = {}
  if type(value) == 'table' then
    for _, item in ipairs(value) do
      out[#out + 1] = tostring(item)
    end
  elseif value ~= nil then
    for part in tostring(value):gmatch('[^,]+') do
      out[#out + 1] = part
    end
  end
  return out
end

local function list_set(name, value)
  list_option_store[name] = to_list(value)
end

local function list_remove_items(list, items)
  local drop = {}
  for _, item in ipairs(items) do
    drop[item] = true
  end
  local kept = {}
  for _, entry in ipairs(list) do
    if not drop[entry] then
      kept[#kept + 1] = entry
    end
  end
  return kept
end

local ListOption = {}
ListOption.__index = ListOption

function ListOption:get()
  return to_list(list_get(self._name))
end

function ListOption:append(value)
  local items = to_list(value)
  local list = list_remove_items(list_get(self._name), items)
  for _, item in ipairs(items) do
    list[#list + 1] = item
  end
  list_option_store[self._name] = list
  return self
end

function ListOption:prepend(value)
  local items = to_list(value)
  local list = list_remove_items(list_get(self._name), items)
  for i = #items, 1, -1 do
    table.insert(list, 1, items[i])
  end
  list_option_store[self._name] = list
  return self
end

function ListOption:remove(value)
  list_option_store[self._name] = list_remove_items(list_get(self._name), to_list(value))
  return self
end

ListOption.__tostring = function(self)
  return table.concat(list_get(self._name), ',')
end

-- Options whose value is a string of single-character flags.
local flag_options = {
  shortmess = true,
  formatoptions = true,
  cpoptions = true,
  guioptions = true,
  mouse = true,
}

-- vim.opt accepts lists ({ 'a', 'b' }) and maps ({ tab = '> ' }) for
-- comma-separated string options; flatten them to the string form.
local function opt_to_string(name, value)
  if type(value) ~= 'table' then
    return value
  end
  local parts = {}
  if #value > 0 then
    for _, item in ipairs(value) do
      parts[#parts + 1] = tostring(item)
    end
    return table.concat(parts, flag_options[name] and '' or ',')
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local item = value[key]
    if item == true then
      parts[#parts + 1] = key
    elseif item ~= false and item ~= nil then
      parts[#parts + 1] = key .. ':' .. tostring(item)
    end
  end
  return table.concat(parts, flag_options[name] and '' or ',')
end

local StringOption = {}
StringOption.__index = StringOption

local function string_option_raw(name)
  return option_mt.__index(nil, name)
end

function StringOption:get()
  local value = string_option_raw(self._name)
  local out = {}
  if flag_options[self._name] then
    for ch in value:gmatch('.') do
      out[ch] = true
    end
    return out
  end
  for part in value:gmatch('[^,]+') do
    out[#out + 1] = part
  end
  return out
end

local function string_items(name, value)
  local text = opt_to_string(name, value)
  local items = {}
  if flag_options[name] then
    for ch in tostring(text):gmatch('.') do
      items[#items + 1] = ch
    end
  else
    for part in tostring(text):gmatch('[^,]+') do
      items[#items + 1] = part
    end
  end
  return items
end

local function string_join(name, items)
  return table.concat(items, flag_options[name] and '' or ',')
end

function StringOption:append(value)
  local name = self._name
  local items = string_items(name, string_option_raw(name))
  local seen = {}
  for _, item in ipairs(items) do
    seen[item] = true
  end
  for _, item in ipairs(string_items(name, value)) do
    if not seen[item] then
      items[#items + 1] = item
    end
  end
  option_mt.__newindex(nil, name, string_join(name, items))
  return self
end

function StringOption:prepend(value)
  local name = self._name
  local added = string_items(name, value)
  local drop = {}
  for _, item in ipairs(added) do
    drop[item] = true
  end
  for _, item in ipairs(string_items(name, string_option_raw(name))) do
    if not drop[item] then
      added[#added + 1] = item
    end
  end
  option_mt.__newindex(nil, name, string_join(name, added))
  return self
end

function StringOption:remove(value)
  local name = self._name
  local drop = {}
  for _, item in ipairs(string_items(name, value)) do
    drop[item] = true
    drop[item:match('^([^:]+):') or item] = true
  end
  local kept = {}
  for _, item in ipairs(string_items(name, string_option_raw(name))) do
    if not (drop[item] or drop[item:match('^([^:]+):') or item]) then
      kept[#kept + 1] = item
    end
  end
  option_mt.__newindex(nil, name, string_join(name, kept))
  return self
end

StringOption.__tostring = function(self)
  return tostring(string_option_raw(self._name))
end

local function opt_newindex(t, k, v)
  local list = list_option_aliases[k]
  if list then
    list_set(list, v)
    return
  end
  return option_mt.__newindex(t, k, opt_to_string(k, v))
end

vim.opt = setmetatable({}, {
  __index = function(t, k)
    local list = list_option_aliases[k]
    if list then
      return setmetatable({ _name = list }, ListOption)
    end
    local value = option_mt.__index(t, k)
    if type(value) == 'string' then
      return setmetatable({ _name = option_aliases[k] or k }, StringOption)
    end
    return value
  end,
  __newindex = opt_newindex,
})

vim.o = setmetatable({}, {
  __index = function(t, k)
    local list = list_option_aliases[k]
    if list then
      return table.concat(list_get(list), ',')
    end
    return option_mt.__index(t, k)
  end,
  __newindex = opt_newindex,
})

vim.go = setmetatable({}, {
  __index = function(_, k)
    local list = list_option_aliases[k]
    if list then
      return table.concat(list_get(list), ',')
    end
    check_option(k)
    local v = option_store[k]
    if v ~= nil then
      return v
    end
    return option_defaults[k]
  end,
  __newindex = function(_, k, v)
    local list = list_option_aliases[k]
    if list then
      list_set(list, v)
      return
    end
    check_option(k)
    option_store[k] = opt_to_string(k, v)
  end,
})
vim.opt_local = vim.opt
vim.opt_global = vim.opt

-- Buffer-local options. `modified` is authoritative in the Zig core; the
-- rest live in this Lua table until the option registry moves down.
local function buf_opt_get(id, k)
  if k == 'modified' then
    return vim._buf_modified(id)
  end
  local opts = buffer_options[id]
  if opts and opts[k] ~= nil then
    return opts[k]
  end
  check_buf_option(k)
  local global = option_store[k]
  if global ~= nil then
    return global
  end
  return option_defaults[k]
end

local function buf_opt_set(id, k, v)
  if k == 'modified' then
    vim._buf_set_modified(id, v)
    return
  end
  check_buf_option(k)
  local opts = buffer_options[id]
  if not opts then
    opts = alias_table({})
    buffer_options[id] = opts
  end
  opts[k] = v
  -- Like :set, changing these options runs the matching events.
  local key = option_aliases[k] or k
  if (key == 'filetype') and type(v) == 'string' then
    vim.api.nvim_exec_autocmds('FileType', { pattern = v, buffer = id })
  elseif key == 'syntax' and type(v) == 'string' then
    vim.api.nvim_exec_autocmds('Syntax', { pattern = v, buffer = id })
  end
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
local window_options = alias_table({})
vim.wo = setmetatable({}, {
  __index = function(_, k)
    check_option(k)
    local v = window_options[k]
    if v ~= nil then
      return v
    end
    v = option_store[k]
    if v ~= nil then
      return v
    end
    return option_defaults[k]
  end,
  __newindex = function(_, k, v)
    check_option(k)
    window_options[k] = v
    option_store[k] = v
  end,
})

-- ------------------------------------------------------------- variables
vim.env = setmetatable({}, {
  __index = function(_, k)
    return os.getenv(k)
  end,
  __newindex = function(_, k, v)
    k = tostring(k)
    if v == nil then
      if vim.uv.os_unsetenv then
        vim.uv.os_unsetenv(k)
      else
        vim.uv.os_setenv(k, '')
      end
    else
      vim.uv.os_setenv(k, tostring(v))
    end
  end,
})

vim.g = setmetatable({}, {
  __index = function() end,
  __newindex = function(t, k, v)
    rawset(t, k, v)
  end,
})

local buffer_vars = {}
local function buffer_var_table(id)
  if id == 0 then
    id = vim.api.nvim_get_current_buf()
  end
  return setmetatable({}, {
    __index = function(_, k)
      local vars = buffer_vars[id]
      return vars and vars[k]
    end,
    __newindex = function(_, k, v)
      local vars = buffer_vars[id]
      if not vars then
        vars = {}
        buffer_vars[id] = vars
      end
      vars[k] = v
    end,
  })
end

vim.b = setmetatable({}, {
  __index = function(_, k)
    if type(k) == 'number' then
      return buffer_var_table(k)
    end
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

-- Stub: nvim__redraw is a private API used by vim.diagnostic and other modules.
-- No-op for now since zigvim doesn't have a real redraw mechanism.
function vim.api.nvim__redraw(_)
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
  -- Match Neovim's directories so user configs and LazyVim distributions are
  -- picked up unchanged.
  if what == 'config' then
    return xdg('XDG_CONFIG_HOME', '/.config') .. '/nvim'
  elseif what == 'data' then
    return xdg('XDG_DATA_HOME', '/.local/share') .. '/nvim'
  elseif what == 'state' then
    return xdg('XDG_STATE_HOME', '/.local/state') .. '/nvim'
  elseif what == 'cache' then
    return xdg('XDG_CACHE_HOME', '/.cache') .. '/nvim'
  elseif what == 'log' then
    return xdg('XDG_STATE_HOME', '/.local/state') .. '/nvim/log'
  end
  return ''
end

function vim.fn.argc(...)
  -- Return the number of files in the argument list.
  -- For now, return 0 (no files opened from command line).
  return 0
end

-- True once filetype detection has set 'filetype' for the buffer. Neovim keeps
-- this in script state; the buffer option is the observable equivalent here.
function vim.fn.did_filetype()
  return vim.bo.filetype ~= '' and 1 or 0
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
  if expr == '~' then
    return home_dir()
  elseif expr:sub(1, 1) == '~' then
    return home_dir() .. expr:sub(2)
  elseif expr:sub(1, 1) == '$' then
    local env, rest = expr:match('^%$([%w_]+)(.*)$')
    if env then
      local value = os.getenv(env) or ''
      return value .. rest
    end
    return ''
  elseif expr:sub(1, 1) == '%' then
    if name == '' then
      return ''
    end
    local modifiers = expr:sub(2)
    if modifiers == '' then
      return name
    end
    return vim.fn.fnamemodify(name, modifiers)
  end
  return expr
end

function vim.fn.line(expr)
  expr = tostring(expr)
  if expr == '$' then
    return vim.api.nvim_buf_line_count(0)
  end
  if expr == '.' or expr == 'w0' or expr == 'w$' then
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  return tonumber(expr) or 0
end

function vim.fn.col(expr)
  expr = tostring(expr)
  if expr == '$' then
    local lines = vim.api.nvim_buf_get_lines(0, vim.api.nvim_win_get_cursor(0)[1] - 1, vim.api.nvim_win_get_cursor(0)[1], false)
    return #(lines[1] or '') + 1
  end
  if expr == '.' then
    return vim.api.nvim_win_get_cursor(0)[2] + 1
  end
  return tonumber(expr) or 0
end

function vim.fn.getpos(expr)
  local row, col = vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[2]
  return { vim.api.nvim_get_current_buf(), row, col + 1, 0 }
end

local function normalize_pos(pos)
  if pos == nil then
    return nil
  end
  if type(pos) == 'table' and pos[1] == 'v' then
    return nil
  end
  local buf = tonumber(pos[1]) or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return { buf, tonumber(pos[2]) or 1, tonumber(pos[3]) or 1, tonumber(pos[4]) or 0 }
end

function vim.fn.getregionpos(pos1, pos2, opts)
  opts = opts or {}
  local start = normalize_pos(pos1)
  local finish = normalize_pos(pos2)
  if not start or not finish then
    return {}
  end
  local regtype = opts.type or 'v'
  local exclusive = opts.exclusive ~= false
  local buf = start[1]
  local lines = vim.api.nvim_buf_get_lines(math.max(buf - 1, 0), 0, -1, false)
  local maxcol = vim.v.maxcol

  local function line_length(lnum)
    return #(lines[lnum] or '')
  end

  local regions = {}
  if regtype == 'V' then
    for lnum = start[2], finish[2] do
      regions[#regions + 1] = { { buf, lnum, 1, 0 }, { buf, lnum, maxcol, 0 } }
    end
    return regions
  end

  if regtype == 'blockwise' or regtype == '\22' then
    local col1, col2 = start[3], finish[3]
    if col1 > col2 then
      col1, col2 = col2, col1
    end
    if exclusive then
      col2 = col2 - 1
    end
    for lnum = start[2], finish[2] do
      local endcol = math.min(col2, line_length(lnum))
      regions[#regions + 1] = { { buf, lnum, col1, 0 }, { buf, lnum, endcol, 0 } }
    end
    return regions
  end

  local from, to = start, finish
  if to[2] < from[2] or (to[2] == from[2] and to[3] < from[3]) then
    from, to = to, from
  end
  local endcol = to[3]
  if exclusive then
    endcol = endcol - 1
  end
  if endcol < 1 then
    return {}
  end
  regions[1] = { { buf, from[2], from[3], 0 }, { buf, to[2], endcol, 0 } }
  return regions
end

function vim.fn.setpos(expr, pos)
  vim.api.nvim_win_set_cursor(0, { pos[2] or 1, math.max((pos[3] or 1) - 1, 0) })
  return 0
end

function vim.fn.getcurpos()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return { vim.api.nvim_get_current_buf(), cursor[1], cursor[2] + 1, 0, cursor[2] + 1 }
end

function vim.fn.cursor(...)
  local args = { ... }
  if type(args[1]) == 'table' then
    args = args[1]
  end
  local row = tonumber(args[1]) or vim.api.nvim_win_get_cursor(0)[1]
  local col = tonumber(args[2]) or 1
  local lines = vim.api.nvim_buf_get_lines(0, row - 1, row, false)
  local length = #(lines[1] or '')
  if col > length then
    col = math.max(length, 1)
  end
  if col < 1 then
    col = 1
  end
  vim.api.nvim_win_set_cursor(0, { row, col - 1 })
  return 0
end

function vim.fn.strwidth(s)
  return vim.api.nvim_strwidth(tostring(s))
end

function vim.fn.strlen(s)
  return #tostring(s)
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

function vim.fn.getftype(path)
  return vim._path_type(tostring(path))
end

function vim.fn.isdirectory(path)
  if vim.fn.getftype(path) == 'dir' then
    return 1
  end
  return 0
end

function vim.fn.mkdir(path, flags)
  path = tostring(path)
  local command
  if vim.uv.os_uname().sysname:match('Windows') then
    command = (flags == 'p' or flags == 'p!')
        and ('if not exist "' .. path .. '" mkdir "' .. path .. '" 2>nul')
      or ('mkdir "' .. path .. '" 2>nul')
  else
    command = "mkdir " .. ((flags == 'p' or flags == 'p!') and '-p ' or '')
      .. "'"
      .. path:gsub("'", "'\\''")
      .. "' 2>/dev/null"
  end
  local ok = os.execute(command)
  if ok == true or ok == 0 then
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

local function fire_autocmd(event, opts)
  if vim._exec_autocmds then
    vim._exec_autocmds(event, opts)
  end
end

-- Autocmds that take over reading/writing a path (BufReadCmd/BufWriteCmd,
-- used by netrw and the archive plugins).
local function special_autocmds(event, pattern)
  local ok, list = pcall(vim.api.nvim_get_autocmds, { event = event, pattern = pattern })
  if ok then
    return list
  end
  return {}
end

local function edit_path(path)
  local full = vim.fn.fnamemodify(path, ':p')
  if #special_autocmds('BufReadCmd', path) > 0 then
    vim.api.nvim_buf_set_name(0, path)
    vim._buf_set_modified(0, false)
    fire_autocmd('BufReadPre', {buffer = 0, pattern = path})
    fire_autocmd('BufReadCmd', {buffer = 0, pattern = path})
    fire_autocmd('BufReadPost', {buffer = 0, pattern = path})
    fire_autocmd('BufEnter', {buffer = 0})
    fire_autocmd('BufWinEnter', {buffer = 0})
    return
  end
  local lines = read_file(full)
  vim.api.nvim_buf_set_name(0, path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or { '' })
  vim._buf_set_modified(0, false)
  fire_autocmd('BufReadPost', {buffer = 0})
  fire_autocmd('BufEnter', {buffer = 0})
  fire_autocmd('BufWinEnter', {buffer = 0})
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
  fire_autocmd('BufWritePre', {buffer = 0})
  if #special_autocmds('BufWriteCmd', target) > 0 then
    fire_autocmd('BufWriteCmd', {buffer = 0, pattern = target})
    fire_autocmd('BufWritePost', {buffer = 0})
    return
  end
  write_file(target, buffer_lines())
  vim._buf_set_modified(0, false)
  fire_autocmd('BufWritePost', {buffer = 0})
end

local function set_option_arg(arg)
  -- name? : Neovim echoes the value; nothing to do here.
  if arg:sub(-1) == '?' then
    return
  end
  -- name& : reset to the default value.
  local reset = arg:match('^([%w_]+)&$')
  if reset then
    option_store[reset] = nil
    return
  end
  -- name! / invname : toggle a boolean option.
  local toggle = arg:match('^([%w_]+)!$') or arg:match('^inv([%w_]+)$')
  if toggle and rawget(option_defaults, toggle) ~= nil or toggle and option_aliases[toggle] then
    vim.o[toggle] = not vim.o[toggle]
    return
  end
  -- name=value, name:value, name+=value, name-=value, name^=value
  local name, op, value = arg:match('^([%w_]+)([%+%-%^]?)[=:](.*)$')
  if name then
    local current = vim.o[name]
    local function typed(v)
      if type(current) == 'number' then
        return tonumber(v) or v
      end
      return v
    end
    if op == '' then
      vim.o[name] = typed(value)
    elseif type(current) == 'number' then
      local n = tonumber(value) or 0
      if op == '+' then
        vim.o[name] = current + n
      elseif op == '-' then
        vim.o[name] = current - n
      else
        vim.o[name] = current * n
      end
    elseif list_option_aliases[name] then
      local option = vim.opt[name]
      if op == '+' then
        option:append(value)
      elseif op == '-' then
        option:remove(value)
      else
        option:prepend(value)
      end
    else
      local option = vim.opt[name]
      if op == '+' then
        option:append(value)
      elseif op == '-' then
        option:remove(value)
      else
        option:prepend(value)
      end
    end
    return
  end
  -- noname : turn a boolean option off. Option names never start with "no".
  local off = arg:match('^no([%w_]+)$')
  if off then
    vim.o[off] = false
    return
  end
  vim.o[arg] = true
end

local function parse_set(arg)
  set_option_arg(arg)
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
      local key, value = option:match('^([^=]+)=(.*)$')
      parse_set(option)
      if key == 'filetype' or key == 'ft' then
        vim.bo.filetype = value
        fire_autocmd('FileType', {pattern = value})
      end
    end
  elseif name == 'setlocal' or name == 'setl' then
    for option in rest:gmatch('%S+') do
      local key, value = option:match('^([%w_]+)[=:](.*)$')
      local target = key or option
      local enable = true
      if not key and option:match('^no[%w_]+$') then
        target = option:sub(3)
        enable = false
      end
      local function assign(v)
        if buffer_local[option_aliases[target] or target] then
          vim.bo[target] = v
        else
          vim.wo[target] = v
        end
      end
      if key then
        local current = vim.o[key]
        assign(type(current) == 'number' and (tonumber(value) or value) or value)
        if key == 'filetype' or key == 'ft' then
          fire_autocmd('FileType', {pattern = value})
        end
      else
        assign(enable)
      end
    end
  elseif name == 'setglobal' or name == 'setg' then
    for option in rest:gmatch('%S+') do
      local key, value = option:match('^([%w_]+)[=:](.*)$')
      if key then
        local current = vim.go[key]
        vim.go[key] = type(current) == 'number' and (tonumber(value) or value) or value
      elseif option:match('^no[%w_]+$') then
        vim.go[option:sub(3)] = false
      else
        vim.go[option] = true
      end
    end
  elseif name == 'luafile' or name == 'luaf' then
    local chunk, err = loadfile(rest)
    if not chunk then
      error("E484: Can't open file " .. rest .. (err and (': ' .. tostring(err)) or ''), 0)
    end
    chunk()
  elseif name == 'source' or name == 'so' then
    local path = rest
    if path:sub(1, 1) == '~' then
      path = home_dir() .. path:sub(2)
    end
    if path:sub(-4) == '.lua' then
      local chunk, err = loadfile(path)
      if not chunk then
        error("E484: Can't open file " .. path .. (err and (': ' .. tostring(err)) or ''), 0)
      end
      chunk()
    elseif vim.fn.filereadable(path) ~= 1 then
      error("E484: Can't open file " .. path, 0)
    end
    -- Vimscript files are not supported yet and are skipped.
  elseif name == 'augroup' or name == 'aug' or name == 'packadd' or name == 'filetype'
    or name == 'syntax' or name == 'syn' or name == 'highlight' or name == 'hi'
    or name == 'highlight!' or name == 'hi!'
    or name == 'menu' or name == 'amenu' or name == 'nmenu' or name == 'vmenu'
    or name == 'imenu' or name == 'cmenu' or name == 'omenu' or name == 'tmenu'
    or name == 'noremenu' or name == 'anoremenu' or name == 'nnoremenu'
    or name == 'vnoremenu' or name == 'inoremenu' or name == 'cnoremenu'
    or name == 'onoremenu' or name == 'tnoremenu'
    or name == 'unmenu' or name == 'aunmenu' then
    -- Accepted and ignored: no Vimscript engine / highlighter / menu system behind these yet.
  elseif name == 'colorscheme' or name == 'colo' then
    local scheme = rest
    if scheme == '' then
      return
    end
    fire_autocmd('ColorSchemePre', { pattern = scheme })
    local found
    for _, ext in ipairs({ 'lua', 'vim' }) do
      found = vim.api.nvim_get_runtime_file('colors/' .. scheme .. '.' .. ext, false)[1]
      if found then
        if ext == 'lua' then
          local chunk, err = loadfile(found)
          if not chunk then
            error(tostring(err), 0)
          end
          chunk()
        else
          -- .vim file: parse and execute simple 'lua' commands
          local f = io.open(found, 'r')
          if f then
            for line in f:lines() do
              local lua_code = line:match('^%s*lua%s+(.*)$')
              if lua_code then
                local chunk, err = loadstring(lua_code)
                if chunk then
                  chunk()
                end
              end
            end
            f:close()
          end
        end
        break
      end
    end
    if not found then
      error('E185: Cannot find color scheme \'' .. scheme .. '\'', 0)
    end
    vim.g.colors_name = vim.g.colors_name or scheme
    fire_autocmd('ColorScheme', { pattern = scheme })
  elseif name == 'runtime' or name == 'ru' or name == 'runtime!' or name == 'ru!' then
    for pattern in rest:gmatch('%S+') do
      for _, file in ipairs(vim.api.nvim_get_runtime_file(pattern, name:sub(-1) == '!')) do
        if file:sub(-4) == '.lua' then
          local chunk = loadfile(file)
          if chunk then
            chunk()
          end
        end
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
  elseif name == 'setf' or name == 'setfiletype' then
    -- :setf [FALLBACK] name / :setfiletype name. Setting 'filetype' fires
    -- FileType (see buf_opt_set), which drives ftplugin/indent loading.
    local args = {}
    for word in rest:gmatch('%S+') do
      args[#args + 1] = word
    end
    local first = args[1]
    local fallback = false
    if first == 'FALLBACK' then
      fallback = true
      table.remove(args, 1)
      first = args[1]
    end
    if name == 'setfiletype' and vim.bo.filetype ~= '' then
      return
    end
    if first and first ~= '' then
      if not fallback then
        vim.b.did_filetype = 1
      end
      vim.bo.filetype = first
    end
  elseif name == 'echo' then
    local chunk, err = loadstring('return ' .. rest)
    if not chunk then
      error(err)
    end
    local value = chunk()
    io.stdout:write(tostring(value) .. '\n')
  elseif vim._user_commands
    and (vim._user_commands[name] or (name:sub(-1) == '!' and vim._user_commands[name:sub(1, -2)])) then
    local bang = name:sub(-1) == '!'
    local user_cmd = vim._user_commands[bang and name:sub(1, -2) or name]
    local fargs = {}
    for word in rest:gmatch('%S+') do
      fargs[#fargs + 1] = word
    end
    local opts = { name = name, args = rest, fargs = fargs, line1 = 1, line2 = 1, bang = bang }
    if type(user_cmd.command) == 'function' then
      user_cmd.command(opts)
    else
      exec_cmd((tostring(user_cmd.command):gsub('<q%-args>', rest):gsub('<args>', rest)))
    end
  else
    api_error('E492: Not an editor command: ' .. cmd)
  end
end

-- Run each line, adding the same context Neovim attaches when a command is
-- executed through vim.cmd(). API callers (nvim_command / nvim_exec2) get the
-- bare "Vim:..." form instead.
local function exec_lines(cmd, wrap)
  if type(cmd) == 'table' then
    cmd = cmd.cmd or cmd[1]
  end
  local line_number = 0
  for line in tostring(cmd):gmatch('[^\n]+') do
    line_number = line_number + 1
    local ok, err = pcall(exec_cmd, line)
    if not ok then
      local msg = tostring(err)
      if msg:sub(1, 4) ~= 'Vim:' then
        msg = 'Vim:' .. msg
      end
      if wrap then
        msg = '[string "vim/_core/editor"]:353: nvim_exec2(), line ' .. line_number .. ': ' .. msg
      end
      api_error(msg)
    end
  end
end

local function cmd_call(cmd)
  exec_lines(cmd, true)
end

-- vim.cmd is both callable (vim.cmd('set x')) and indexable
-- (vim.cmd.colorscheme('tokyonight'), vim.cmd.edit({ args = { 'f' }, bang = true })).
vim.cmd = setmetatable({}, {
  __call = function(_, cmd)
    return cmd_call(cmd)
  end,
  __index = function(_, name)
    return function(...)
      local args = { ... }
      local line = name
      local parts = {}
      local first = args[1]
      if type(first) == 'table' then
        if first.bang then
          line = line .. '!'
        end
        for _, arg in ipairs(first.args or {}) do
          parts[#parts + 1] = tostring(arg)
        end
      else
        for _, arg in ipairs(args) do
          parts[#parts + 1] = tostring(arg)
        end
      end
      if #parts > 0 then
        line = line .. ' ' .. table.concat(parts, ' ')
      end
      return cmd_call(line)
    end
  end,
})

local function exec_lua(code, args)
  local chunk, err = loadstring(code)
  if not chunk then
    error(err)
  end
  return chunk(unpack(args or {}))
end

vim.api.nvim_command = function(cmd)
  exec_lines(cmd, false)
end

-- Minimal nvim_cmd(): enough for callers (Neovim's runtime, plugins) that build
-- commands from a table instead of a string. Unknown commands fall back to the
-- same :command parser the rest of the editor uses.
vim.api.nvim_cmd = function(cmd, _opts)
  cmd = cmd or {}
  local name = cmd.cmd or ''
  local args = cmd.args or {}
  if name == '' then
    api_error("Invalid 'cmd': expected a command name")
  end
  local parts = { name }
  if cmd.bang then
    parts[1] = name .. '!'
  end
  for _, arg in ipairs(args) do
    parts[#parts + 1] = tostring(arg)
  end
  if cmd.count and cmd.count ~= 0 then
    table.insert(parts, 2, tostring(cmd.count))
  end
  exec_lines(table.concat(parts, ' '), false)
  return nil
end

vim.api.nvim_exec2 = function(src, _)
  exec_lines(src, false)
  return { output = '' }
end

vim.api.nvim_exec_lua = function(code, args)
  return exec_lua(code, args)
end

vim.api.nvim_buf_is_loaded = function(buf)
  return vim.api.nvim_buf_is_valid(buf)
end

local buffer_attach_callbacks = {}

vim.api.nvim_buf_attach = function(buf, send_buffer, opts)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local callbacks = buffer_attach_callbacks[buf]
  if not callbacks then
    callbacks = {}
    buffer_attach_callbacks[buf] = callbacks
  end
  callbacks[#callbacks + 1] = opts or {}
  return true
end

vim.api.nvim_buf_detach = function(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  buffer_attach_callbacks[buf] = nil
  return true
end

local function fire_buf_attach(buf, firstline, lastline, new_lastline)
  local callbacks = buffer_attach_callbacks[buf]
  if not callbacks then
    return
  end
  for _, opts in ipairs(callbacks) do
    if opts.on_lines then
      opts.on_lines(nil, buf, nil, firstline, lastline, new_lastline)
    end
  end
end

vim.api.nvim_win_call = function(win, fn)
  local prev = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  local ok, result = pcall(fn)
  vim.api.nvim_set_current_win(prev)
  if not ok then
    error(result)
  end
  return result
end

-- Native helper Neovim's shared library uses for vim._with().
vim._with_c = function(context, fn)
  if context.buf then
    return vim.api.nvim_buf_call(context.buf, fn)
  end
  if context.win then
    return vim.api.nvim_win_call(context.win, fn)
  end
  return fn()
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

-- ------------------------------------------------- runtimepath + require
-- Neovim's `require` also searches <runtimepath>/lua/. Without this a user
-- config (~/.config/nvim/lua/config/lazy.lua) and plugins prepended to
-- 'runtimepath' (lazy.nvim) can never be found.
do
  local function rtp_searcher(modname)
    local rel = modname:gsub('%.', '/')
    for _, dir in ipairs(list_get('runtimepath')) do
      for _, candidate in ipairs({
        dir .. '/lua/' .. rel .. '.lua',
        dir .. '/lua/' .. rel .. '/init.lua',
      }) do
        local f = io.open(candidate, 'rb')
        if f then
          f:close()
          local chunk, err = loadfile(candidate)
          if not chunk then
            error("error loading module '" .. modname .. "' from file '" .. candidate .. "':\n\t" .. tostring(err), 0)
          end
          return chunk
        end
      end
    end
    return "\n\tno file '" .. rel .. "' in runtimepath"
  end
  local searchers = package.loaders or package.searchers
  table.insert(searchers, 2, rtp_searcher)
end

vim.api.nvim_list_runtime_paths = function()
  return to_list(list_get('runtimepath'))
end

-- Expand {a,b} alternatives, as Neovim does for :runtime patterns.
local function expand_braces(pattern)
  local start = pattern:find('{', 1, true)
  if not start then
    return { pattern }
  end
  local finish = pattern:find('}', start, true)
  if not finish then
    return { pattern }
  end
  local prefix, body, suffix = pattern:sub(1, start - 1), pattern:sub(start + 1, finish - 1), pattern:sub(finish + 1)
  local out = {}
  for alt in (body .. ','):gmatch('([^,]*),') do
    for _, expanded in ipairs(expand_braces(prefix .. alt .. suffix)) do
      out[#out + 1] = expanded
    end
  end
  return out
end
vim._expand_braces = expand_braces

vim.api.nvim_get_runtime_file = function(name, all)
  local found = {}
  for _, dir in ipairs(list_get('runtimepath')) do
    for _, sub in ipairs(expand_braces(name)) do
      local pattern = dir .. '/' .. sub
      local matches
      if pattern:find('[*?]') then
        matches = vim.fn.glob(pattern, false, true)
      elseif vim.uv.fs_stat(pattern) then
        matches = { pattern }
      else
        matches = {}
      end
      for _, match in ipairs(matches) do
        found[#found + 1] = match
        if not all then
          return found
        end
      end
    end
  end
  return found
end

vim.api.nvim_echo = function(chunks, _history, opts)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    parts[#parts + 1] = tostring(chunk[1])
  end
  local stream = (opts and opts.err) and io.stderr or io.stdout
  stream:write(table.concat(parts) .. '\n')
end

function vim.fn.getchar()
  return 27
end

function vim.in_fast_event()
  return false
end

-- Completion candidates; only colorschemes are backed by real data so far.
function vim.fn.getcompletion(pat, kind)
  local out = {}
  if kind == 'color' then
    local seen = {}
    for _, ext in ipairs({ 'lua', 'vim' }) do
      for _, file in ipairs(vim.api.nvim_get_runtime_file('colors/*.' .. ext, true)) do
        local name = file:match('([^/]+)%.' .. ext .. '$')
        if name and not seen[name] then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    end
    table.sort(out)
  end
  if pat ~= nil and pat ~= '' then
    local filtered = {}
    for _, item in ipairs(out) do
      if item:sub(1, #pat) == pat then
        filtered[#filtered + 1] = item
      end
    end
    return filtered
  end
  return out
end

function vim.fn.executable(name)
  name = tostring(name)
  if name == '' then
    return 0
  end
  local command
  if name:find('/', 1, true) then
    command = "test -x '" .. name:gsub("'", "'\\''") .. "' >/dev/null 2>&1"
  else
    command = "command -v '" .. name:gsub("'", "'\\''") .. "' >/dev/null 2>&1"
  end
  local ok = os.execute(command)
  return (ok == true or ok == 0) and 1 or 0
end

function vim.fn.getscriptinfo()
  return {}
end

vim.api.nvim_list_uis = function()
  return {}
end

-- $VIMRUNTIME points at the runtime shipped with zigvim.
if os.getenv('VIMRUNTIME') == nil then
  vim.uv.os_setenv('VIMRUNTIME', runtime_root())
end

-- luv's fs_scandir() returns a handle consumed by fs_scandir_next(); the Zig
-- core returns a plain list of names. Wrap it so both styles work.
do
  local list_scandir = vim.uv.fs_scandir
  vim.uv._scandir_list = list_scandir
  vim.uv.fs_scandir = function(path)
    local names = list_scandir(path)
    if not names then
      return nil
    end
    return { path = path, names = names, index = 0 }
  end
  vim.uv.fs_scandir_next = function(handle)
    handle.index = handle.index + 1
    local name = handle.names[handle.index]
    if not name then
      return nil
    end
    local stat = vim.uv.fs_stat(handle.path .. '/' .. name)
    return name, stat and stat.type or 'file'
  end
end

vim.loop = vim.uv

-- Handles that need a running libuv loop are inert for now.
vim.uv.new_check = function()
  local handle = {}
  function handle.start()
    return 0
  end
  function handle.stop()
    return 0
  end
  function handle.close() end
  function handle.is_active()
    return false
  end
  return handle
end
vim.uv.fs_lstat = vim.uv.fs_stat
vim.uv.available_parallelism = function()
  return 4
end

-- File descriptors on top of io.* (enough for the module cache and lazy.nvim).
vim.uv.fs_open = function(path, flags, _mode)
  local mode = 'rb'
  if type(flags) == 'string' then
    if flags:find('a') then
      mode = 'ab'
    elseif flags:find('w') then
      mode = 'wb'
    end
  end
  local file = io.open(path, mode)
  if not file then
    return nil
  end
  return { _file = file }
end
vim.uv.fs_close = function(fd)
  fd._file:close()
  return true
end
vim.uv.fs_read = function(fd, size, offset)
  if offset and offset >= 0 then
    fd._file:seek('set', offset)
  end
  return fd._file:read(size) or ''
end
vim.uv.fs_write = function(fd, data, offset)
  if offset and offset >= 0 then
    fd._file:seek('set', offset)
  end
  fd._file:write(data)
  return #data
end
vim.uv.fs_fstat = function(fd)
  local current = fd._file:seek()
  local size = fd._file:seek('end')
  fd._file:seek('set', current)
  return { size = size, type = 'file', mtime = { sec = 0, nsec = 0 } }
end

-- Canonical names for special keys (Neovim normalizes to these forms).
-- Defined early so nvim_replace_termcodes can use it.
local special_key_names = {
  ['<cr>'] = '<CR>', ['<CR>'] = '<CR>', ['<Cr>'] = '<CR>', ['<cR>'] = '<CR>',
  ['<enter>'] = '<CR>', ['<return>'] = '<CR>',
  ['<space>'] = '<Space>', ['<SPACE>'] = '<Space>',
  ['<tab>'] = '<Tab>', ['<TAB>'] = '<Tab>',
  ['<esc>'] = '<Esc>', ['<ESC>'] = '<Esc>',
  ['<bs>'] = '<BS>', ['<BS>'] = '<BS>', ['<backspace>'] = '<BS>',
  ['<del>'] = '<Del>', ['<DEL>'] = '<Del>', ['<delete>'] = '<Del>',
  ['<insert>'] = '<Insert>', ['<ins>'] = '<Insert>',
  ['<home>'] = '<Home>', ['<end>'] = '<End>',
  ['<pageup>'] = '<PageUp>', ['<pagedown>'] = '<PageDown>',
  ['<up>'] = '<Up>', ['<down>'] = '<Down>', ['<left>'] = '<Left>', ['<right>'] = '<Right>',
  ['<f1>'] = '<F1>', ['<f2>'] = '<F2>', ['<f3>'] = '<F3>', ['<f4>'] = '<F4>',
  ['<f5>'] = '<F5>', ['<f6>'] = '<F6>', ['<f7>'] = '<F7>', ['<f8>'] = '<F8>',
  ['<f9>'] = '<F9>', ['<f10>'] = '<F10>', ['<f11>'] = '<F11>', ['<f12>'] = '<F12>',
  ['<lt>'] = '<lt>', ['<lt'] = '<lt>',
  ['<bar>'] = '<Bar>', ['<Bar>'] = '<Bar>',
  ['<bslash>'] = '<Bslash>', ['<Bslash>'] = '<Bslash>',
  ['<nul>'] = '<Nul>', ['<Nul>'] = '<Nul>',
  ['<nop>'] = '<Nop>', ['<Nop>'] = '<Nop>',
}

vim.api.nvim_replace_termcodes = function(str, from_part, do_lt, special)
  if type(str) ~= 'string' then
    return str
  end
  -- Expand <leader> and <localleader>
  local leader = vim.g.mapleader
  if leader == nil or leader == '' then
    leader = '\\'
  end
  local localleader = vim.g.maplocalleader
  if localleader == nil or localleader == '' then
    localleader = '\\'
  end
  
  local result = str:gsub('<[Ll][Ee][Aa][Dd][Ee][Rr]>', leader)
  result = result:gsub('<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>', localleader)
  
  -- Normalize control characters and special keys
  local out = {}
  local i = 1
  local len = #result
  while i <= len do
    if result:sub(i, i) == '<' then
      local j = result:find('>', i + 1, true)
      if j then
        local token = result:sub(i, j)
        local token_lower = token:lower()
        
        -- Check for <Space> - normalize to literal space
        if token_lower == '<space>' then
          table.insert(out, ' ')
          i = j + 1
        -- Check for <Plug> - keep whole
        elseif token_lower == '<plug>' then
          table.insert(out, token)
          i = j + 1
          while i <= len do
            table.insert(out, result:sub(i, i))
            i = i + 1
          end
          break
        else
          -- Control character
          local ctrl_match = token:match('^<[Cc]%-(.)>$')
          if ctrl_match then
            local ch = ctrl_match:upper()
            table.insert(out, '<C-' .. ch .. '>')
            i = j + 1
          else
            -- Special key
            local normalized = special_key_names[token_lower]
            if normalized then
              table.insert(out, normalized)
              i = j + 1
            else
              -- Modifier keys: <S-x>, <M-x>, <A-x>, <D-x>, <C-x>
              local mod, key = token:match('^<([SsMmAaDdCc])%-(.+)>$')
              if mod then
                mod = mod:upper()
                local key_normalized = special_key_names['<' .. key:lower() .. '>']
                if key_normalized then
                  key = key_normalized:sub(2, -2)
                end
                -- <S-a> through <S-z> normalize to uppercase letters
                if mod == 'S' and #key == 1 and key:match('[a-zA-Z]') then
                  table.insert(out, key:upper())
                else
                  table.insert(out, '<' .. mod .. '-' .. key .. '>')
                end
                i = j + 1
              else
                -- Unknown token, normalize < to <lt> and reprocess rest
                table.insert(out, '<lt>')
                i = i + 1
              end
            end
          end
        end
      else
        -- No closing >, normalize < to <lt>
        table.insert(out, '<lt>')
        i = i + 1
      end
    else
      table.insert(out, result:sub(i, i))
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Minimal vim.loader: Neovim's own implementation needs far more of the uv
-- API than zigvim provides. Module lookup goes through the rtp searcher above,
-- so enable()/disable() are no-ops; find() is used by lazy.nvim.
vim.loader = {
  enabled = false,
  path = vim.fn.stdpath('cache') .. '/luac',
  enable = function() end,
  disable = function() end,
  reset = function() end,
  _profile = function() end,
  _inspect = function()
    return {}
  end,
  find = function(modname, opts)
    opts = opts or {}
    local results = {}
    local dirs = {}
    if opts.rtp ~= false then
      for _, dir in ipairs(list_get('runtimepath')) do
        dirs[#dirs + 1] = dir
      end
    end
    for _, dir in ipairs(opts.paths or {}) do
      dirs[#dirs + 1] = dir
    end
    modname = modname:gsub('/', '.')
    if modname == '*' then
      for _, dir in ipairs(dirs) do
        for _, name in ipairs(vim.uv._scandir_list(dir .. '/lua') or {}) do
          local top = name:match('^(.+)%.lua$') or (not name:find('.', 1, true) and name or nil)
          if top then
            results[#results + 1] = { modpath = dir .. '/lua/' .. name, modname = top }
          end
        end
      end
      return results
    end
    local basename = modname:gsub('%.', '/')
    local patterns = opts.patterns or { '/init.lua', '.lua' }
    for _, dir in ipairs(dirs) do
      for _, pattern in ipairs(patterns) do
        local path = dir .. '/lua/' .. basename .. pattern
        local stat = vim.uv.fs_stat(path)
        if stat then
          results[#results + 1] = { modpath = path, modname = modname, stat = stat }
          if not opts.all then
            return results
          end
        end
      end
    end
    return results
  end,
}

-- Load the user's init.lua when running as an editor (not for -l scripts).
-- Startup sequence, mirroring Neovim: user init.lua, then filetype/syntax
-- defaults, then every plugin/*.lua on the runtimepath. `skip_user_config`
-- implements --clean (defaults and runtime plugins still run, as in nvim).
function vim._startup(skip_user_config)
  if not skip_user_config then
    local path = vim.fn.stdpath('config') .. '/init.lua'
    local f = io.open(path, 'r')
    if f then
      f:close()
      local ok, err = pcall(dofile, path)
      if not ok then
        io.stderr:write('Error in init.lua: ' .. tostring(err) .. '\n')
      end
    end
  end

  -- Neovim enables filetype detection, ftplugins, indent and syntax between
  -- init.lua and the runtime plugins; plugins may rely on it being on.
  vim._setup_filetype()

  -- Source runtime plugins (plugin/*.lua files from runtime path)
  local rtp = vim.o.runtimepath
  if rtp and rtp ~= '' then
    for dir in rtp:gmatch('[^,]+') do
      local plugin_dir = dir .. '/plugin'
      local stat = vim.uv.fs_stat(plugin_dir)
      if stat and stat.type == 'directory' then
        local files = vim.uv._scandir_list(plugin_dir) or {}
        table.sort(files)  -- Sort to ensure consistent loading order
        for _, name in ipairs(files) do
          if name:match('%.lua$') then
            local plugin_path = plugin_dir .. '/' .. name
            local plugin_ok, plugin_err = pcall(dofile, plugin_path)
            if not plugin_ok then
              io.stderr:write('Error in ' .. plugin_path .. ': ' .. tostring(plugin_err) .. '\n')
            end
          end
          -- Skip .vim files for now (no Vimscript engine yet)
        end
      end
    end
  end

  return true
end

function vim._load_init()
  return vim._startup(false)
end

-- ----------------------------------------------------------- variables API
local window_vars = {}
local tab_vars = {}
local vvars = {
  version = 801,
  lua = true,
  maxcol = 2147483647,
  numbermax = 9223372036854775807,
  numbermin = -9223372036854775808,
  errmsg = '',
  shell_error = 0,
  count = 0,
  count1 = 1,
  prevcount = 0,
  hlsearch = 1,
  searchforward = 1,
  register = '"',
  operator = '',
  dying = 0,
  exception = '',
  statusmsg = '',
  warningmsg = '',
  scrollstart = '',
  this_session = '',
  termresponse = '',
  servername = '',
  progpath = '',
  argv = {},
  errors = {},
  oldfiles = {},
  completed_item = {},
  event = {},
  windowid = 0,
  mouse_win = 0,
  mouse_lnum = 0,
  mouse_col = 0,
  echospace = 0,
  beval_bufnr = 0,
  beval_lnum = 0,
  beval_col = 0,
  beval_text = '',
  beval_winnr = 0,
  charconvert_from = '',
  charconvert_to = '',
  ['true'] = true,
  ['false'] = false,
}

local function var_table(kind, id)
  if kind == 'g' then
    return vim.g
  elseif kind == 'b' then
    local vars = buffer_vars[id]
    if not vars then
      vars = {}
      buffer_vars[id] = vars
    end
    return vars
  elseif kind == 'w' then
    local vars = window_vars[id]
    if not vars then
      vars = {}
      window_vars[id] = vars
    end
    return vars
  elseif kind == 't' then
    local vars = tab_vars[id]
    if not vars then
      vars = {}
      tab_vars[id] = vars
    end
    return vars
  end
  return {}
end

local function get_var(kind, id, name)
  local value = var_table(kind, id)[name]
  if value == nil then
    api_error('Key not found: ' .. name)
  end
  return value
end

local function set_var(kind, id, name, value)
  var_table(kind, id)[name] = value
end

local function del_var(kind, id, name)
  local vars = var_table(kind, id)
  if vars[name] == nil then
    api_error('Key not found: ' .. name)
  end
  vars[name] = nil
end

vim.api.nvim_get_var = function(name)
  return get_var('g', nil, name)
end
vim.api.nvim_set_var = function(name, value)
  set_var('g', nil, name, value)
end
vim.api.nvim_del_var = function(name)
  del_var('g', nil, name)
end

vim.api.nvim_get_vvar = function(name)
  local value = vvars[name]
  if value == nil then
    api_error('Key not found: ' .. name)
  end
  return value
end
vim.api.nvim_set_vvar = function(name, value)
  vvars[name] = value
end

-- v: , w: and t: proxies over the same storage the API uses.
vim.v = setmetatable({}, {
  __index = function(_, k)
    return vvars[k]
  end,
  __newindex = function(_, k, v)
    vvars[k] = v
  end,
})
vim.w = setmetatable({}, {
  __index = function(_, k)
    return var_table('w', vim.api.nvim_get_current_win())[k]
  end,
  __newindex = function(_, k, v)
    var_table('w', vim.api.nvim_get_current_win())[k] = v
  end,
})
vim.t = setmetatable({}, {
  __index = function(_, k)
    return var_table('t', vim.api.nvim_get_current_tabpage())[k]
  end,
  __newindex = function(_, k, v)
    var_table('t', vim.api.nvim_get_current_tabpage())[k] = v
  end,
})

vim.api.nvim_buf_get_var = function(buf, name)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  return get_var('b', buf, name)
end
vim.api.nvim_buf_set_var = function(buf, name, value)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  set_var('b', buf, name, value)
end
vim.api.nvim_buf_del_var = function(buf, name)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  del_var('b', buf, name)
end

vim.api.nvim_win_get_var = function(win, name)
  win = win == 0 and vim.api.nvim_get_current_win() or win
  return get_var('w', win, name)
end
vim.api.nvim_win_set_var = function(win, name, value)
  win = win == 0 and vim.api.nvim_get_current_win() or win
  set_var('w', win, name, value)
end
vim.api.nvim_win_del_var = function(win, name)
  win = win == 0 and vim.api.nvim_get_current_win() or win
  del_var('w', win, name)
end

vim.api.nvim_tabpage_get_var = function(tab, name)
  tab = tab == 0 and vim.api.nvim_get_current_tabpage() or tab
  return get_var('t', tab, name)
end
vim.api.nvim_tabpage_set_var = function(tab, name, value)
  tab = tab == 0 and vim.api.nvim_get_current_tabpage() or tab
  set_var('t', tab, name, value)
end
vim.api.nvim_tabpage_del_var = function(tab, name)
  tab = tab == 0 and vim.api.nvim_get_current_tabpage() or tab
  del_var('t', tab, name)
end

-- ------------------------------------------------------------- options API
local function option_value(name, opts)
  opts = opts or {}
  if list_option_aliases[name] then
    return table.concat(list_get(list_option_aliases[name]), ',')
  end
  check_option(name)
  if opts.buf and opts.buf ~= 0 then
    return buf_opt_get(opts.buf, name)
  elseif opts.win and opts.win ~= 0 then
    local value = window_options[name]
    if value == nil then
      value = option_store[name]
    end
    if value ~= nil then
      return value
    end
    return option_defaults[name]
  end
  if name == 'modified' and (opts.buf or opts.scope == 'local') then
    return vim.bo.modified
  end
  local value = option_store[name]
  if value ~= nil then
    return value
  end
  if opts.buf or opts.win then
    return vim.bo[name]
  end
  return option_defaults[name]
end

local function set_option_value(name, value, opts)
  opts = opts or {}
  if list_option_aliases[name] then
    list_set(list_option_aliases[name], value)
    return
  end
  check_option(name)
  if opts.buf and opts.buf ~= 0 then
    buf_opt_set(opts.buf, name, value)
  elseif opts.win and opts.win ~= 0 then
    window_options[name] = value
    option_store[name] = value
  else
    option_store[name] = value
  end
end

vim.api.nvim_get_option_value = function(name, opts)
  return option_value(name, opts)
end
vim.api.nvim_set_option_value = function(name, value, opts)
  set_option_value(name, value, opts)
end
vim.api.nvim_get_option = function(name)
  return option_value(name, {})
end
vim.api.nvim_set_option = function(name, value)
  set_option_value(name, value, {})
end
vim.api.nvim_buf_get_option = function(buf, name)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  check_buf_option(name)
  return buf_opt_get(buf, name)
end
vim.api.nvim_buf_set_option = function(buf, name, value)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  check_buf_option(name)
  buf_opt_set(buf, name, value)
end
vim.api.nvim_win_get_option = function(win, name)
  check_buf_option(name)
  local value = window_options[name]
  if value == nil then
    value = option_store[name]
  end
  if value ~= nil then
    return value
  end
  return option_defaults[name]
end
vim.api.nvim_win_set_option = function(win, name, value)
  check_buf_option(name)
  window_options[name] = value
  option_store[name] = value
end
vim.api.nvim_get_all_options_info = function()
  local info = {}
  for name in pairs(option_defaults) do
    info[name] = { name = name, type = type(option_defaults[name]) }
  end
  return info
end

-- ------------------------------------------------------------- keymaps API
local keymaps = {}
local buffer_keymaps = {}

local function norm_mode(mode)
  if mode == '' or mode == nil then
    return 'n'
  end
  return mode
end

local function find_keymap(list, lhs)
  for _, map in ipairs(list) do
    if map.lhs == lhs then
      return map
    end
  end
  return nil
end

-- Spell an lhs the way nvim_get_keymap() reports it: <c-s> -> <C-S>, <leader> and
-- <Space> -> the literal key, <S-h> -> H, <a-j> -> <M-j>, a lone '<' -> <lt>.
-- shortcut: lhs only; rhs, mode bits and lhsraw are not normalized, add them when a plugin reads them.
local key_names = {}
for name in ([[CR Esc Tab BS Del NL Nul Up Down Left Right Home End PageUp PageDown Insert Help Undo
  Plug Cmd SNR Space lt Bar Bslash Ignore kUp kDown kLeft kRight kHome kEnd kOrigin kPageUp kPageDown
  kDel kPlus kMinus kMultiply kDivide kPoint kComma kEqual kEnter LeftMouse LeftDrag LeftRelease
  MiddleMouse MiddleDrag MiddleRelease RightMouse RightDrag RightRelease X1Mouse X1Drag X1Release
  X2Mouse X2Drag X2Release ScrollWheelUp ScrollWheelDown ScrollWheelLeft ScrollWheelRight MouseMove]]):gmatch('%S+') do
  key_names[name:lower()] = name
end
for i = 1, 37 do
  key_names['f' .. i] = 'F' .. i
end
for i = 0, 9 do
  key_names['k' .. i] = 'k' .. i
end
key_names['return'], key_names['enter'] = 'CR', 'CR'

local mod_letters = { s = 'S', c = 'C', m = 'M', a = 'M', t = 'T', d = 'D' }
local char_names = { [' '] = 'Space', ['|'] = 'Bar', ['\\'] = 'Bslash' }
local plain_names = { Space = ' ', Bar = '|', Bslash = '\\', lt = '<lt>' }

local function normalize_lhs(lhs)
  if type(lhs) ~= 'string' then
    return lhs
  end
  local out, i = {}, 1
  while i <= #lhs do
    local inner = lhs:sub(i, i) == '<' and lhs:match('^<([^<>]+)>', i)
    local mods, name = {}, inner
    while name do
      local letter, rest = name:match('^(%a)%-(.+)$')
      if letter and mod_letters[letter:lower()] then
        mods[mod_letters[letter:lower()]] = true
        name = rest
      else
        break
      end
    end
    local lower = name and name:lower()
    local special = lower and key_names[lower]
    local is_char = name and name:match('^[\1-\127\194-\244][\128-\191]*$')
    local has_mods = next(mods) ~= nil
    local leader = name and not has_mods and (lower == 'leader' or lower == 'localleader')
    if leader then
      local value = vim.g[lower == 'leader' and 'mapleader' or 'maplocalleader']
      out[#out + 1] = (type(value) == 'string' and value ~= '') and value or '\\'
    elseif special or is_char then
      local key = special or name
      if not special and key:match('^%a$') then
        if mods.C then
          key = key:upper()
        elseif mods.S then
          key, mods.S = key:upper(), nil
        end
        has_mods = next(mods) ~= nil
      end
      local named = char_names[key] or key
      if has_mods then
        local prefix = ''
        for _, letter in ipairs({ 'M', 'T', 'C', 'S', 'D' }) do
          prefix = prefix .. (mods[letter] and (letter .. '-') or '')
        end
        out[#out + 1] = '<' .. prefix .. named .. '>'
      else
        out[#out + 1] = plain_names[named] or (special and ('<' .. named .. '>')) or key
      end
    end
    if leader or special or is_char then
      i = i + #inner + 2
    else
      local ch = lhs:sub(i, i)
      out[#out + 1] = ch == '<' and '<lt>' or ch
      i = i + 1
    end
  end
  return table.concat(out)
end

local function make_keymap(mode, lhs, rhs, opts)
  opts = opts or {}
  local normalized = normalize_lhs(lhs)
  local map = {
    lhs = normalized,
    lhsraw = lhs,
    mode = norm_mode(mode),
    noremap = (opts.noremap == true or opts.remap ~= true) and 1 or 0,
    silent = opts.silent and 1 or 0,
    desc = opts.desc,
    callback = type(rhs) == 'function' and rhs or nil,
    rhs = type(rhs) == 'function' and '' or tostring(rhs or ''),
  }
  return map
end

local function find_keymap(list, lhs)
  local normalized = normalize_lhs(lhs)
  for _, map in ipairs(list) do
    if map.lhs == normalized then
      return map
    end
  end
  return nil
end

vim.api.nvim_set_keymap = function(mode, lhs, rhs, opts)
  local map = make_keymap(mode, lhs, rhs, opts)
  local list = keymaps[map.mode] or {}
  keymaps[map.mode] = list
  local existing = find_keymap(list, lhs)
  if existing then
    for key, value in pairs(map) do
      existing[key] = value
    end
  else
    list[#list + 1] = map
  end
end

vim.api.nvim_get_keymap = function(mode)
  local m = norm_mode(mode)
  -- v mode includes x and s; x includes v; s includes v
  local sources = {m}
  if m == 'v' then
    sources = {'v', 'x', 's'}
  elseif m == 'x' then
    sources = {'v', 'x'}
  elseif m == 's' then
    sources = {'v', 's'}
  end
  
  local copy = {}
  local seen = {}
  for _, src in ipairs(sources) do
    local list = keymaps[src] or {}
    for _, map in ipairs(list) do
      -- Avoid duplicates (same lhs)
      if not seen[map.lhs] then
        seen[map.lhs] = true
        copy[#copy + 1] = {
          lhs = map.lhs,
          mode = map.mode,
          noremap = map.noremap,
          silent = map.silent,
          desc = map.desc,
          callback = map.callback,
          rhs = map.rhs,
          buffer = 0,
          nowait = map.nowait or 0,
          expr = map.expr or 0,
          script = 0,
          sid = 0,
          lnum = 0,
        }
      end
    end
  end
  return copy
end

vim.api.nvim_del_keymap = function(mode, lhs)
  local list = keymaps[norm_mode(mode)]
  if list then
    local normalized = normalize_lhs(lhs)
    for i, map in ipairs(list) do
      if map.lhs == normalized then
        table.remove(list, i)
        return
      end
    end
  end
  api_error('E31: No such mapping')
end

local function buf_keymap_list(buf, mode)
  local per_buffer = buffer_keymaps[buf]
  if not per_buffer then
    per_buffer = {}
    buffer_keymaps[buf] = per_buffer
  end
  local list = per_buffer[norm_mode(mode)]
  if not list then
    list = {}
    per_buffer[norm_mode(mode)] = list
  end
  return list
end

vim.api.nvim_buf_set_keymap = function(buf, mode, lhs, rhs, opts)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local list = buf_keymap_list(buf, mode)
  local map = make_keymap(mode, lhs, rhs, opts)
  local existing = find_keymap(list, lhs)
  if existing then
    for key, value in pairs(map) do
      existing[key] = value
    end
  else
    list[#list + 1] = map
  end
end

vim.api.nvim_buf_get_keymap = function(buf, mode)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local list = buf_keymap_list(buf, mode)
  local copy = {}
  for i, map in ipairs(list) do
    -- Return a copy with normalized lhs
    copy[i] = {
      lhs = map.lhs,
      mode = map.mode,
      noremap = map.noremap,
      silent = map.silent,
      desc = map.desc,
      callback = map.callback,
      rhs = map.rhs,
      buffer = buf,
      nowait = map.nowait or 0,
      expr = map.expr or 0,
      script = 0,
      sid = 0,
      lnum = 0,
    }
  end
  return copy
end

vim.api.nvim_buf_del_keymap = function(buf, mode, lhs)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local list = buf_keymap_list(buf, mode)
  local normalized = normalize_lhs(lhs)
  for i, map in ipairs(list) do
    if map.lhs == normalized then
      table.remove(list, i)
      return
    end
  end
  api_error('E31: No such mapping')
end

vim.keymap = {
  set = function(modes, lhs, rhs, opts)
    opts = opts or {}
    local mode_list = type(modes) == 'table' and modes or { modes }
    for _, mode in ipairs(mode_list) do
      if opts.buffer then
        vim.api.nvim_buf_set_keymap(opts.buffer == true and 0 or opts.buffer, mode, lhs, rhs, opts)
      else
        vim.api.nvim_set_keymap(mode, lhs, rhs, opts)
      end
    end
  end,
  del = function(modes, lhs, opts)
    opts = opts or {}
    local mode_list = type(modes) == 'table' and modes or { modes }
    for _, mode in ipairs(mode_list) do
      if opts.buffer then
        vim.api.nvim_buf_del_keymap(opts.buffer == true and 0 or opts.buffer, mode, lhs)
      else
        vim.api.nvim_del_keymap(mode, lhs)
      end
    end
  end,
}

-- -------------------------------------------------------- user commands API
vim._user_commands = {}
local user_commands = vim._user_commands
local buffer_user_commands = {}

vim.api.nvim_create_user_command = function(name, command, opts)
  user_commands[name] = {
    name = name,
    command = command,
    nargs = (opts and opts.nargs) or 0,
    desc = opts and opts.desc,
  }
end

vim.api.nvim_del_user_command = function(name)
  if user_commands[name] == nil then
    api_error('Invalid command (not found): ' .. tostring(name))
  end
  user_commands[name] = nil
end

vim.api.nvim_get_commands = function(_)
  local out = {}
  for name, cmd in pairs(user_commands) do
    out[name] = { name = name, nargs = tostring(cmd.nargs), desc = cmd.desc }
  end
  return out
end

vim.api.nvim_buf_create_user_command = function(buf, name, command, opts)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  buffer_user_commands[buf] = buffer_user_commands[buf] or {}
  buffer_user_commands[buf][name] = { command = command, opts = opts }
end

vim.api.nvim_buf_del_user_command = function(buf, name)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local cmds = buffer_user_commands[buf]
  if not cmds or cmds[name] == nil then
    api_error('Invalid command (not found): ' .. tostring(name))
  end
  cmds[name] = nil
end

-- ------------------------------------------------- API argument validation
-- The Zig-backed primitives resolve ids leniently; Neovim raises for invalid
-- handles. Wrap them once so every entry point reports the same error text.
do
  local function check_buf(buf)
    local id = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
    if not vim.api.nvim_buf_is_valid(id) then
      api_error('Invalid buffer id: ' .. tostring(buf))
    end
    return id
  end

  local function check_win(win)
    local id = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
    if not vim.api.nvim_win_is_valid(id) then
      api_error('Invalid window id: ' .. tostring(win))
    end
    return id
  end

  local function check_tab(tab)
    local id = (tab == nil or tab == 0) and vim.api.nvim_get_current_tabpage() or tab
    if not vim.api.nvim_tabpage_is_valid(id) then
      api_error('Invalid tabpage id: ' .. tostring(tab))
    end
    return id
  end

  local buf_funcs = {
    'nvim_buf_get_lines',
    'nvim_buf_set_lines',
    'nvim_buf_line_count',
    'nvim_buf_get_name',
    'nvim_buf_set_name',
    'nvim_buf_delete',
    'nvim_buf_get_var',
    'nvim_buf_set_var',
    'nvim_buf_del_var',
    'nvim_buf_get_option',
    'nvim_buf_set_option',
    'nvim_buf_get_keymap',
    'nvim_buf_set_keymap',
    'nvim_buf_del_keymap',
    'nvim_buf_call',
    'nvim_buf_create_user_command',
    'nvim_buf_del_user_command',
  }
  for _, name in ipairs(buf_funcs) do
    local raw = vim.api[name]
    vim.api[name] = function(buf, ...)
      return raw(check_buf(buf), ...)
    end
  end

  local raw_set_lines = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(buf, start, end_, strict, lines)
    local id = check_buf(buf)
    local result = raw_set_lines(id, start, end_, strict, lines)
    local count = 0
    if type(lines) == 'table' then
      for _ in pairs(lines) do
        count = count + 1
      end
    end
    fire_buf_attach(id, start, end_, start + count)
    return result
  end

  vim.api.nvim_buf_get_short_name = function(buf, _)
    return vim._buf_short_name(check_buf(buf))
  end

  local win_funcs = {
    'nvim_win_get_cursor',
    'nvim_win_get_height',
    'nvim_win_get_width',
    'nvim_win_get_position',
    'nvim_win_get_number',
    'nvim_win_get_buf',
    'nvim_win_get_var',
    'nvim_win_set_var',
    'nvim_win_del_var',
    'nvim_win_get_option',
    'nvim_win_set_option',
  }
  for _, name in ipairs(win_funcs) do
    local raw = vim.api[name]
    vim.api[name] = function(win, ...)
      return raw(check_win(win), ...)
    end
  end

  local raw_win_set_buf = vim.api.nvim_win_set_buf
  vim.api.nvim_win_set_buf = function(win, buf)
    return raw_win_set_buf(check_win(win), check_buf(buf))
  end

  local raw_win_set_cursor = vim.api.nvim_win_set_cursor
  vim.api.nvim_win_set_cursor = function(win, pos)
    local id = check_win(win)
    local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(id))
    if type(pos) ~= 'table' or type(pos[1]) ~= 'number' or pos[1] < 1 or pos[1] > line_count then
      api_error('Invalid cursor line: out of range')
    end
    return raw_win_set_cursor(id, pos)
  end

  local raw_set_current_buf = vim.api.nvim_set_current_buf
  vim.api.nvim_set_current_buf = function(buf)
    return raw_set_current_buf(check_buf(buf))
  end

  local raw_set_current_win = vim.api.nvim_set_current_win
  vim.api.nvim_set_current_win = function(win)
    return raw_set_current_win(check_win(win))
  end

  local tab_funcs = {
    'nvim_tabpage_get_var',
    'nvim_tabpage_set_var',
    'nvim_tabpage_del_var',
    'nvim_tabpage_get_win',
    'nvim_tabpage_get_number',
  }
  for _, name in ipairs(tab_funcs) do
    local raw = vim.api[name]
    vim.api[name] = function(tab, ...)
      return raw(check_tab(tab), ...)
    end
  end
end

-- ---------------------------------------------------------------- autocmds
do
  local known_events = {}
  for _, event in ipairs({
    'BufAdd', 'BufDelete', 'BufEnter', 'BufFilePost', 'BufFilePre', 'BufHidden',
    'BufLeave', 'BufNew', 'BufNewFile', 'BufRead', 'BufReadCmd', 'BufReadPost',
    'BufReadPre', 'BufUnload', 'BufWinEnter', 'BufWinLeave', 'BufWipeout',
    'BufWriteCmd', 'BufWritePost', 'BufWritePre', 'ChanInfo', 'ChanOpen',
    'CmdUndefined', 'CmdlineChanged', 'CmdlineEnter', 'CmdlineLeave',
    'CmdwinEnter', 'CmdwinLeave', 'ColorScheme', 'ColorSchemePre',
    'CompleteChanged', 'CompleteDone', 'CompleteDonePre', 'CursorHold',
    'CursorHoldI', 'CursorMoved', 'CursorMovedI', 'DiagnosticChanged',
    'DiffUpdated', 'DirChanged', 'DirChangedPre', 'EncodingChanged',
    'ExitPre', 'FileAppendPost', 'FileAppendPre', 'FileChangedRO',
    'FileChangedShell', 'FileChangedShellPost', 'FileEncoding',
    'FileReadCmd', 'FileReadPost', 'FileReadPre', 'FileType', 'FileWriteCmd',
    'FileWritePost', 'FileWritePre', 'FilterReadPost', 'FilterReadPre',
    'FilterWritePost', 'FilterWritePre', 'FocusGained', 'FocusLost',
    'FuncUndefined', 'GUIEnter', 'GUIFailed', 'InsertChange', 'InsertCharPre',
    'InsertEnter', 'InsertLeave', 'InsertLeavePre', 'LspAttach', 'LspDetach',
    'LspNotify', 'LspProgress', 'LspRequest', 'MenuPopup', 'ModeChanged',
    'OptionSet', 'QuickFixCmdPost', 'QuickFixCmdPre', 'QuitPre',
    'RecordingEnter', 'RecordingLeave', 'RemoteReply', 'SafeState',
    'SafeStateAgain', 'SearchWrapped', 'SessionLoadPost', 'ShellCmdPost',
    'ShellFilterPost', 'SourceCmd', 'SourcePost', 'SourcePre',
    'SpellFileMissing', 'StdinReadPost', 'StdinReadPre', 'SwapExists',
    'Syntax', 'TabClosed', 'TabEnter', 'TabLeave', 'TabNew', 'TabNewEntered',
    'TermClose', 'TermEnter', 'TermLeave', 'TermOpen', 'TermRequest',
    'TermResponse', 'TextChanged', 'TextChangedI', 'TextChangedP',
    'TextChangedT', 'TextYankPost', 'UIEnter', 'UILeave', 'User',
    'UserGettingBored', 'VimEnter', 'VimLeave', 'VimLeavePre', 'VimResized',
    'VimResume', 'VimSuspend', 'WinClosed', 'WinEnter', 'WinLeave', 'WinNew',
    'WinResized', 'WinScrolled',
  }) do
    known_events[event] = true
  end

  -- Events whose pattern is matched against a buffer name.
  local buffer_events = {
    BufAdd = true, BufDelete = true, BufEnter = true, BufFilePost = true,
    BufFilePre = true, BufHidden = true, BufLeave = true, BufNew = true,
    BufNewFile = true, BufReadCmd = true, BufReadPost = true,
    BufReadPre = true, BufUnload = true, BufWinEnter = true,
    BufWinLeave = true, BufWipeout = true, BufWriteCmd = true,
    BufWritePost = true, BufWritePre = true, FileReadCmd = true,
    FileReadPost = true, FileReadPre = true, FileWriteCmd = true,
    FileWritePost = true, FileWritePre = true,
  }

  local state = {
    next_id = 1,
    next_group = 1,
    groups = {},       -- name -> id
    group_names = {},  -- id -> name
    items = {},        -- id -> record
  }

  local function glob_match(glob, text)
    if glob == '*' then
      return true
    end
    local pattern = glob:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%1')
    pattern = pattern:gsub('%*', '.*'):gsub('%?', '.')
    return text:match('^' .. pattern .. '$') ~= nil
  end

  local function as_list(value)
    if type(value) == 'table' then
      return value
    end
    return { value }
  end

  local function validate_events(events)
    local list = as_list(events)
    for _, event in ipairs(list) do
      if not known_events[event] then
        api_error("Invalid 'event': '" .. tostring(event) .. "'")
      end
    end
    return list
  end

  local function remove_id(id)
    state.items[id] = nil
  end

  vim.api.nvim_create_augroup = function(name, opts)
    opts = opts or {}
    local id = state.groups[name]
    if id then
      if opts.clear then
        for autocmd_id, record in pairs(state.items) do
          if record.group == id then
            state.items[autocmd_id] = nil
          end
        end
      end
      return id
    end
    id = state.next_group
    state.next_group = state.next_group + 1
    state.groups[name] = id
    state.group_names[id] = name
    return id
  end

  local function delete_group(id)
    for autocmd_id, record in pairs(state.items) do
      if record.group == id then
        state.items[autocmd_id] = nil
      end
    end
    local name = state.group_names[id]
    if name then
      state.groups[name] = nil
      state.group_names[id] = nil
    end
  end

  vim.api.nvim_del_augroup_by_name = function(name)
    local id = state.groups[name]
    if not id then
      api_error('Invalid group: ' .. tostring(name))
    end
    delete_group(id)
  end

  vim.api.nvim_del_augroup_by_id = function(id)
    delete_group(id)
  end

  vim.api.nvim_create_autocmd = function(events, opts)
    opts = opts or {}
    local list = validate_events(events)
    if opts.callback == nil and opts.command == nil then
      api_error("Invalid 'callback': Expected Lua function or 'command'")
    end
    if opts.callback ~= nil and opts.command ~= nil then
      api_error("Invalid 'callback': Cannot use both 'command' and 'callback'")
    end
    if opts.pattern ~= nil and opts.buffer ~= nil then
      api_error("Conflict: 'pattern' not allowed with 'buf'")
    end
    local group = opts.group
    if type(group) == 'string' then
      group = state.groups[group]
    end
    group = group or 0
    local id = state.next_id
    state.next_id = state.next_id + 1
    local record = {
      id = id,
      events = list,
      group = group,
      pattern = opts.pattern and as_list(opts.pattern) or { '*' },
      buffer = opts.buffer,
      callback = opts.callback,
      command = opts.command,
      once = opts.once and true or false,
      nested = opts.nested and true or false,
      desc = opts.desc,
    }
    state.items[id] = record
    return id
  end

  vim.api.nvim_del_autocmd = function(id)
    remove_id(id)
  end

  local function contains(list, value)
    for _, item in ipairs(list) do
      if item == value then
        return true
      end
    end
    return false
  end

  local function record_has_event(record, event)
    for _, value in ipairs(record.events) do
      if value == event then
        return true
      end
    end
    return false
  end

  local function record_matches_pattern(record, patterns)
    if not record.pattern then
      return false
    end
    for _, expected in ipairs(patterns) do
      for _, glob in ipairs(record.pattern) do
        if glob == expected or glob_match(glob, expected) then
          return true
        end
      end
    end
    return record.pattern[1] == '*'
  end

  vim.api.nvim_get_autocmds = function(filter)
    filter = filter or {}
    local event_filter = filter.event and validate_events(filter.event) or nil
    local pattern_filter = filter.pattern and as_list(filter.pattern) or nil
    local group_filter = filter.group
    if type(group_filter) == 'string' then
      local name = group_filter
      group_filter = state.groups[name]
      if not group_filter then
        api_error("Invalid 'group': '" .. name .. "'")
      end
    elseif group_filter ~= nil and not state.group_names[group_filter] and group_filter ~= 0 then
      api_error("Invalid 'group': '" .. tostring(group_filter) .. "'")
    end
    local entries = {}
    for _, record in pairs(state.items) do
      local event_ok = true
      if event_filter then
        event_ok = false
        for _, event in ipairs(event_filter) do
          if record_has_event(record, event) then
            event_ok = true
            break
          end
        end
      end
      local group_ok = group_filter == nil or record.group == group_filter
      local buffer_ok = filter.buffer == nil or record.buffer == filter.buffer
      local pattern_ok = true
      if pattern_filter then
        pattern_ok = record_matches_pattern(record, pattern_filter)
      end
      if event_ok and group_ok and buffer_ok and pattern_ok then
        for _, event in ipairs(record.events) do
          if not event_filter or contains(event_filter, event) then
            entries[#entries + 1] = {
              id = record.id,
              event = event,
              group = record.group,
              group_name = state.group_names[record.group],
              pattern = record.pattern and record.pattern[1] or nil,
              command = record.command or '',
              callback = record.callback,
              once = record.once,
              nested = record.nested,
              desc = record.desc,
              buffer = record.buffer,
            }
          end
        end
      end
    end
    table.sort(entries, function(a, b)
      if a.event == b.event then
        return a.id < b.id
      end
      return a.event < b.event
    end)
    return entries
  end

  local function buffer_name_for(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == '' then
      return ''
    end
    local cwd = vim.fn.getcwd()
    if cwd ~= '' and name:sub(1, #cwd + 1) == cwd .. '/' then
      return name:sub(#cwd + 2)
    end
    return name
  end

  -- Vim's event aliases: an autocmd registered for BufRead also runs when
  -- BufReadPost fires (and BufWrite for BufWritePre).
  local function expand_event_aliases(events)
    local out, seen = {}, {}
    local function add(name)
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
    for _, name in ipairs(events) do
      add(name)
      if name == 'BufReadPost' then
        add('BufRead')
      elseif name == 'BufWritePre' then
        add('BufWrite')
      end
    end
    return out
  end

  vim._exec_autocmds = function(event, opts)
    opts = opts or {}
    local events = expand_event_aliases(validate_events(event))
    local buffer = opts.buffer
    if buffer == nil or buffer == 0 then
      buffer = vim.api.nvim_get_current_buf()
    end
    local patterns = opts.pattern and as_list(opts.pattern) or nil
    for _, single_event in ipairs(events) do
      local candidates = patterns
      if not candidates then
        if buffer_events[single_event] then
          candidates = { buffer_name_for(buffer) }
        else
          candidates = { opts.pattern or '' }
        end
      end
      local snapshot = {}
      for _, record in pairs(state.items) do
        if record_has_event(record, single_event) then
          snapshot[#snapshot + 1] = record
        end
      end
      table.sort(snapshot, function(a, b)
        return a.id < b.id
      end)
      for _, record in ipairs(snapshot) do
        local matches = false
        local match_text = candidates[1] or ''
        if record.buffer then
          matches = record.buffer == buffer
          if matches and patterns then
            match_text = patterns[1]
          end
        else
          for _, candidate in ipairs(candidates) do
            if record.pattern and record.pattern[1] then
              for _, glob in ipairs(record.pattern) do
                if glob == '*' or glob == candidate or glob_match(glob, candidate) then
                  matches = true
                  match_text = candidate
                  break
                end
              end
            end
            if matches then
              break
            end
          end
        end
        if matches and state.items[record.id] then
          if record.once then
            state.items[record.id] = nil
          end
          local args = {
            id = record.id,
            event = single_event,
            match = match_text,
            buf = buffer,
            file = vim.api.nvim_buf_get_name(buffer),
            data = opts.data,
          }
          if record.command then
            exec_cmd(record.command)
          elseif record.callback then
            record.callback(args)
          end
        end
      end
    end
  end

  vim.api.nvim_exec_autocmds = function(event, opts)
    vim._exec_autocmds(event, opts)
  end

  vim.api.nvim_clear_autocmds = function(opts)
    opts = opts or {}
    local event_filter = opts.event and validate_events(opts.event) or nil
    local pattern_filter = opts.pattern and as_list(opts.pattern) or nil
    for id, record in pairs(state.items) do
      local remove = true
      if event_filter then
        remove = false
        for _, event in ipairs(event_filter) do
          if record_has_event(record, event) then
            remove = true
            break
          end
        end
      end
      if remove and opts.group ~= nil and record.group ~= opts.group then
        remove = false
      end
      if remove and opts.buffer ~= nil and record.buffer ~= opts.buffer then
        remove = false
      end
      if remove and pattern_filter and not record_matches_pattern(record, pattern_filter) then
        remove = false
      end
      if remove then
        state.items[id] = nil
      end
    end
  end
end

-- ------------------------------------------------------- namespaces and HL
do
  local namespace_names = {}
  local next_namespace = 1

  vim.api.nvim_create_namespace = function(name)
    if name == nil or name == '' then
      local id = next_namespace
      next_namespace = next_namespace + 1
      return id
    end
    local id = namespace_names[name]
    if id then
      return id
    end
    id = next_namespace
    next_namespace = next_namespace + 1
    namespace_names[name] = id
    return id
  end

  vim.api.nvim_get_namespaces = function()
    local out = {}
    for name, id in pairs(namespace_names) do
      out[name] = id
    end
    return out
  end

  local named_colors = {
    black = 0x000000, darkblue = 0x00008b, darkgreen = 0x006400,
    darkcyan = 0x008b8b, darkred = 0x8b0000, darkmagenta = 0x8b008b,
    brown = 0xa52a2a, darkyellow = 0xbbbb00, lightgray = 0xd3d3d3,
    lightgrey = 0xd3d3d3, gray = 0x808080, grey = 0x808080,
    darkgray = 0xa9a9a9, darkgrey = 0xa9a9a9, blue = 0x0000ff,
    lightblue = 0xadd8e6, green = 0x00ff00, lightgreen = 0x90ee90,
    cyan = 0x00ffff, lightcyan = 0xe0ffff, red = 0xff0000,
    lightred = 0xffbbbb, magenta = 0xff00ff, lightmagenta = 0xffbbff,
    yellow = 0xffff00, lightyellow = 0xffffe0, white = 0xffffff,
    darkgrey2 = 0x808080,
  }

  local function color_value(value)
    if type(value) == 'number' then
      return value
    end
    if type(value) ~= 'string' then
      return nil
    end
    local hex = value:match('^#(%x%x%x%x%x%x)$')
    if hex then
      return tonumber(hex, 16)
    end
    local short = value:match('^#(%x%x%x)$')
    if short then
      local r, g, b = short:sub(1, 1), short:sub(2, 2), short:sub(3, 3)
      return tonumber(r .. r .. g .. g .. b .. b, 16)
    end
    return named_colors[value:lower()]
  end

  local attr_keys = {
    'bold', 'italic', 'underline', 'undercurl', 'underdouble', 'underdotted',
    'underdashed', 'strikethrough', 'reverse', 'standout', 'nocombine',
    'altfont', 'dim', 'blink',
  }

  local highlight_groups = {}
  local next_hl_id = 1
  local hl_ids = {}

  vim.api.nvim_get_hl_id_by_name = function(name)
    local id = hl_ids[name]
    if not id then
      id = next_hl_id
      next_hl_id = next_hl_id + 1
      hl_ids[name] = id
    end
    return id
  end

  vim.api.nvim_set_hl = function(ns, name, val)
    val = val or {}
    local group = highlight_groups[name] or {}
    if val.link and val.link ~= '' then
      group.link = val.link
      group.fg = nil
      group.bg = nil
      group.sp = nil
    else
      group.link = nil
      for _, key in ipairs({ 'fg', 'bg', 'sp', 'foreground', 'background', 'special' }) do
        if val[key] ~= nil then
          local target = key
          if key == 'foreground' then
            target = 'fg'
          elseif key == 'background' then
            target = 'bg'
          elseif key == 'special' then
            target = 'sp'
          end
          group[target] = color_value(val[key]) or group[target]
        end
      end
      for _, key in ipairs(attr_keys) do
        if val[key] ~= nil then
          group[key] = val[key] and true or nil
        end
      end
      if val.cterm ~= nil then
        local cterm = {}
        for _, key in ipairs({ 'fg', 'bg', 'sp' }) do
          if val.cterm[key] ~= nil then
            cterm[key] = color_value(val.cterm[key]) or val.cterm[key]
          end
        end
        for _, key in ipairs(attr_keys) do
          if val.cterm[key] ~= nil then
            cterm[key] = val.cterm[key] and true or nil
          end
        end
        if next(cterm) ~= nil then
          group.cterm = cterm
        end
      end
      if val.default then
        group.default = true
      end
    end
    highlight_groups[name] = group
    return 0
  end

  vim.api.nvim_get_hl = function(ns, opts)
    opts = opts or {}
    local function copy_group(group)
      local copy = {}
      for key, value in pairs(group) do
        if type(value) == 'table' then
          local nested = {}
          for k, v in pairs(value) do
            nested[k] = v
          end
          copy[key] = nested
        else
          copy[key] = value
        end
      end
      return copy
    end
    if opts.name ~= nil then
      local group = highlight_groups[opts.name]
      if not group then
        return {}
      end
      local copy = copy_group(group)
      if opts.link == false then
        copy.link = nil
      end
      return copy
    end
    local out = {}
    for name, group in pairs(highlight_groups) do
      local copy = copy_group(group)
      if opts.link == false then
        copy.link = nil
      end
      out[name] = copy
    end
    return out
  end

  vim.api.nvim_set_hl_ns = function(ns) end
  vim.api.nvim_win_set_hl_ns = function(win, ns) end
  vim.api.nvim_get_hl_ns = function(_) return 0 end
end

-- Load Neovim's shipped runtime modules that build on the API above.
package.preload['vim.uv'] = function()
  return vim.uv
end
package.preload['vim.loop'] = function()
  return vim.uv
end

do
  local modules = {
    'vim.F', 'vim.func', 'vim.fs', 'vim.iter', 'vim.text', 'vim.re', 'vim.pos',
    'vim.range', 'vim.net', 'vim.filetype', 'vim.secure', 'vim.pack',
    'vim.health', 'vim.loader', 'vim._watch', 'vim.version', 'vim.hl',
    'vim.keymap',
  }
  for _, mod in ipairs(modules) do
    local field = mod:sub(5)
    if vim[field] == nil then
      local ok, lib = pcall(require, mod)
      if ok and lib ~= nil then
        vim[field] = lib
      end
    end
  end
end

-- Lazy-load heavy modules on first access (matches Neovim's behavior)
do
  local lazy_modules = {
    diagnostic = 'vim.diagnostic',
    lsp = 'vim.lsp',
    treesitter = 'vim.treesitter',
  }
  local vim_mt = getmetatable(vim) or {}
  local old_index = vim_mt.__index
  vim_mt.__index = function(t, k)
    local modname = lazy_modules[k]
    if modname then
      local ok, lib = pcall(require, modname)
      if ok and lib ~= nil then
        rawset(t, k, lib)
        return lib
      end
    end
    if old_index then
      return old_index(t, k)
    end
    return nil
  end
  setmetatable(vim, vim_mt)
end

-- ----------------------------------------------------------- extmarks API
do
  local extmarks = {}      -- buffer id -> namespace id -> { id -> mark }
  local next_extmark_id = 1

  local function ns_marks(buf, ns)
    local per_buffer = extmarks[buf]
    if not per_buffer then
      per_buffer = {}
      extmarks[buf] = per_buffer
    end
    local marks = per_buffer[ns]
    if not marks then
      marks = {}
      per_buffer[ns] = marks
    end
    return marks
  end

  vim.api.nvim_buf_set_extmark = function(buf, ns, line, col, opts)
    opts = opts or {}
    local marks = ns_marks(buf, ns)
    local id = opts.id or next_extmark_id
    if not opts.id then
      next_extmark_id = next_extmark_id + 1
    end
    marks[id] = {
      id = id,
      row = line,
      col = col,
      end_row = opts.end_row,
      end_col = opts.end_col,
      hl_group = opts.hl_group,
      hl_eol = opts.hl_eol,
      priority = opts.priority,
      virt_text = opts.virt_text,
      virt_text_pos = opts.virt_text_pos,
      virt_lines = opts.virt_lines,
      sign_text = opts.sign_text,
      sign_hl_group = opts.sign_hl_group,
      number_hl_group = opts.number_hl_group,
      line_hl_group = opts.line_hl_group,
      cursorline_hl_group = opts.cursorline_hl_group,
      conceal = opts.conceal,
      spell = opts.spell,
      ui_watched = opts.ui_watched,
      right_gravity = opts.right_gravity,
      end_right_gravity = opts.end_right_gravity,
      strict = opts.strict,
      ephemeral = opts.ephemeral,
    }
    return id
  end

  vim.api.nvim_buf_get_extmarks = function(buf, ns, start, end_, opts)
    opts = opts or {}
    local marks = ns_marks(buf, ns)
    local start_row = 0
    local start_col = 0
    if type(start) == 'table' then
      start_row, start_col = start[1] or 0, start[2] or 0
    else
      start_row = start or 0
    end
    local end_row, end_col
    if end_ == nil or end_ == -1 then
      end_row, end_col = math.huge, math.huge
    elseif type(end_) == 'table' then
      end_row, end_col = end_[1] or 0, end_[2] or 0
    else
      end_row, end_col = end_, math.huge
    end
    local out = {}
    for _, mark in pairs(marks) do
      local after_start = mark.row > start_row or (mark.row == start_row and (mark.col or 0) >= start_col)
      local before_end = mark.row < end_row or (mark.row == end_row and (mark.col or 0) <= end_col)
      if (opts.type == nil or true) and after_start and before_end then
        if opts.details then
          local details = { }
          for _, key in ipairs({
            'end_row', 'end_col', 'hl_group', 'hl_eol', 'priority', 'virt_text',
            'virt_text_pos', 'virt_lines', 'sign_text', 'sign_hl_group',
            'number_hl_group', 'line_hl_group', 'cursorline_hl_group', 'conceal',
            'spell', 'ui_watched', 'right_gravity', 'end_right_gravity',
          }) do
            details[key] = mark[key]
          end
          out[#out + 1] = { mark.id, mark.row, mark.col, details }
        else
          out[#out + 1] = { mark.id, mark.row, mark.col }
        end
      end
    end
    table.sort(out, function(a, b)
      if a[2] == b[2] then
        if a[3] == b[3] then
          return a[1] < b[1]
        end
        return a[3] < b[3]
      end
      return a[2] < b[2]
    end)
    return out
  end

  vim.api.nvim_buf_get_extmark_by_id = function(buf, ns, id, opts)
    opts = opts or {}
    local marks = ns_marks(buf, ns)
    local mark = marks[id]
    if not mark then
      return {}
    end
    if opts.details then
      return { mark.row, mark.col, { end_row = mark.end_row, end_col = mark.end_col, hl_group = mark.hl_group } }
    end
    return { mark.row, mark.col }
  end

  vim.api.nvim_buf_del_extmark = function(buf, ns, id)
    local marks = ns_marks(buf, ns)
    if marks[id] == nil then
      return false
    end
    marks[id] = nil
    return true
  end

  vim.api.nvim_buf_clear_namespace = function(buf, ns, line_start, line_end)
    local buffer_marks = extmarks[buf] or {}
    if ns == -1 then
      for _, marks in pairs(buffer_marks) do
        for id, mark in pairs(marks) do
          if mark.row >= line_start and mark.row < line_end then
            marks[id] = nil
          end
        end
      end
      return
    end
    local marks = ns_marks(buf, ns)
    for id, mark in pairs(marks) do
      if mark.row >= line_start and mark.row < line_end then
        marks[id] = nil
      end
    end
  end

  vim.api.nvim_create_namespace = vim.api.nvim_create_namespace
end

-- ---------------------------------------------------- vim.fn editing helpers
do
  local registers = {}

  local function current_lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  local function to_line_number(expr, bufline_count)
    expr = tostring(expr)
    if expr == '.' then
      return vim.api.nvim_win_get_cursor(0)[1]
    elseif expr == '$' then
      return bufline_count
    end
    local num = tonumber(expr)
    if num then
      return num
    end
    return 0
  end

  function vim.fn.getline(expr, end_)
    local lines = current_lines()
    local first = to_line_number(expr, #lines)
    if first < 1 then
      return ''
    end
    local last = first
    if end_ ~= nil then
      last = to_line_number(end_, #lines)
    end
    if last < first then
      return ''
    end
    if end_ == nil then
      return lines[first] or ''
    end
    local out = {}
    for lnum = first, math.min(last, #lines) do
      out[#out + 1] = lines[lnum]
    end
    return out
  end

  function vim.fn.getbufline(buf, first, end_)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    first = to_line_number(first, #lines)
    end_ = end_ == nil and first or to_line_number(end_, #lines)
    if first < 1 or end_ < first then
      return {}
    end
    local out = {}
    for lnum = first, math.min(end_, #lines) do
      out[#out + 1] = lines[lnum]
    end
    return out
  end

  function vim.fn.setline(lnum, text)
    lnum = to_line_number(lnum, #current_lines())
    if lnum < 1 then
      return 1
    end
    local replacement = type(text) == 'table' and text or { tostring(text) }
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum + #replacement - 1, false, replacement)
    return 0
  end

  function vim.fn.append(lnum, text)
    lnum = to_line_number(lnum, #current_lines())
    local lines = type(text) == 'table' and text or { tostring(text) }
    vim.api.nvim_buf_set_lines(0, math.max(lnum, 0), math.max(lnum, 0), false, lines)
    return 0
  end

  function vim.fn.deletebufline(buf, first, end_)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    local count = vim.api.nvim_buf_line_count(buf)
    first = to_line_number(first, count)
    end_ = end_ == nil and first or to_line_number(end_, count)
    if first < 1 or first > count then
      return 0
    end
    end_ = math.min(end_, count)
    vim.api.nvim_buf_set_lines(buf, first - 1, end_, false, {})
    return 1
  end

  function vim.fn.bufnr(expr)
    expr = tostring(expr)
    if expr == '%' or expr == '' then
      return vim.api.nvim_get_current_buf()
    elseif expr == '$' then
      local buffers = vim.api.nvim_list_bufs()
      return buffers[#buffers] or -1
    elseif expr == '#' then
      return -1
    end
    local num = tonumber(expr)
    if num then
      return vim.api.nvim_buf_is_valid(num) and num or -1
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name == expr then
        return buf
      end
      if name ~= '' then
        local base = vim.fn.fnamemodify(name, ':t')
        if base == expr or name:sub(-#expr) == expr then
          return buf
        end
      end
    end
    return -1
  end

  function vim.fn.bufname(expr)
    expr = tostring(expr)
    if expr == '%' then
      return vim.api.nvim_buf_get_name(0)
    end
    local buf = vim.fn.bufnr(expr)
    if buf < 1 then
      return ''
    end
    return vim.api.nvim_buf_get_name(buf)
  end

  function vim.fn.bufexists(expr)
    return vim.fn.bufnr(expr) >= 1 and 1 or 0
  end

  function vim.fn.buflisted(expr)
    return vim.fn.bufexists(expr)
  end

  function vim.fn.getbufvar(buf, name, default)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or vim.fn.bufnr(buf)
    if buf < 1 or not vim.api.nvim_buf_is_valid(buf) then
      return default
    end
    local ok, value = pcall(vim.api.nvim_buf_get_var, buf, name)
    if not ok then
      return default ~= nil and default or ''
    end
    return value
  end

  function vim.fn.setbufvar(buf, name, value)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or vim.fn.bufnr(buf)
    if buf >= 1 and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_var(buf, name, value)
    end
    return 0
  end

  function vim.fn.getwinvar(win, name, default)
    win = win == 0 and vim.api.nvim_get_current_win() or win
    if win == nil or win < 0 then
      return default
    end
    local ok, value = pcall(vim.api.nvim_win_get_var, win, name)
    if not ok then
      return default ~= nil and default or ''
    end
    return value
  end

  function vim.fn.setwinvar(win, name, value)
    win = win == 0 and vim.api.nvim_get_current_win() or win
    if win ~= nil and win > 0 then
      vim.api.nvim_win_set_var(win, name, value)
    end
    return 0
  end

  function vim.fn.gettabvar(tab, name, default)
    tab = tab == 0 and vim.api.nvim_get_current_tabpage() or tab
    local ok, value = pcall(vim.api.nvim_tabpage_get_var, tab, name)
    if not ok then
      return default ~= nil and default or ''
    end
    return value
  end

  function vim.fn.settabvar(tab, name, value)
    tab = tab == 0 and vim.api.nvim_get_current_tabpage() or tab
    vim.api.nvim_tabpage_set_var(tab, name, value)
    return 0
  end

  function vim.fn.gettabwinvar(tab, win, name, default)
    return vim.fn.getwinvar(win, name, default)
  end

  function vim.fn.getreg(reg, ...)
    reg = reg == nil or reg == '' and '"' or tostring(reg)
    return registers[reg] or ''
  end

  function vim.fn.setreg(reg, value, opts)
    reg = tostring(reg == nil or reg == '' and '"' or reg)
    registers[reg] = value
    return 0
  end

  function vim.fn.getregtype(reg)
    reg = tostring(reg == nil or reg == '' and '"' or reg)
    if registers[reg] == nil then
      return ''
    end
    return 'v'
  end

  function vim.fn.strchars(s)
    s = tostring(s)
    local count = 0
    for _ in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      count = count + 1
    end
    return count
  end

  function vim.fn.strdisplaywidth(s, col)
    return vim.api.nvim_strwidth(tostring(s))
  end

  function vim.fn.strpart(s, start, len, ...)
    s = tostring(s)
    start = tonumber(start) or 0
    if len == nil then
      return s:sub(start + 1)
    end
    if tonumber(len) < 0 then
      return s:sub(start + 1)
    end
    return s:sub(start + 1, start + tonumber(len))
  end

  function vim.fn.stridx(haystack, needle, start)
    haystack, needle = tostring(haystack), tostring(needle)
    local from = (tonumber(start) or 0) + 1
    local found = haystack:find(needle, from, true)
    if not found then
      return -1
    end
    return found - 1
  end

  function vim.fn.escape(s, chars)
    s, chars = tostring(s), tostring(chars)
    return (s:gsub('[' .. chars:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1') .. ']', '\\%0'))
  end

  function vim.fn.fnameescape(s)
    return (tostring(s):gsub('([%s\\!%[%]%*%?%%#$\'"`|{}<>])', '\\%1'))
  end

  function vim.fn.shellescape(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
  end
end

do
  -- Text helpers.
  function vim.fn.split(s, sep, ...)
    s = tostring(s)
    local keepempty = false
    for _, opt in ipairs({ ... }) do
      if opt == 1 then
        keepempty = true
      end
    end
    local out = {}
    if sep == nil or sep == '' then
      for ch in s:gmatch('.') do
        out[#out + 1] = ch
      end
      return out
    end
    sep = tostring(sep)
    local pattern = '([^' .. sep:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1') .. ']*)'
    for part in s:gmatch(pattern) do
      if part ~= '' or keepempty then
        out[#out + 1] = part
      end
    end
    return out
  end

  function vim.fn.join(list, sep)
    local parts = {}
    for _, value in ipairs(list) do
      parts[#parts + 1] = tostring(value)
    end
    return table.concat(parts, sep or ' ')
  end

  function vim.fn.toupper(s)
    return tostring(s):upper()
  end

  function vim.fn.tolower(s)
    return tostring(s):lower()
  end

  vim.fn['repeat'] = function(s, count)
    return string.rep(tostring(s), tonumber(count) or 0)
  end

  -- Feature detection. zigvim reports the Neovim version it emulates so that
  -- plugins performing version checks follow their Neovim code path.
  local emulated = { major = 0, minor = 12, patch = 6 }

  function vim.fn.has(feature)
    feature = tostring(feature)
    if feature == 'nvim' or feature == 'nvim_lua' or feature == 'lua' then
      return 1
    end
    -- Accept both nvim-0.8 and nvim-0.8.0 (lazy.nvim asks for the latter).
    local major, minor, patch = feature:match('^nvim%-(%d+)%.(%d+)%.?(%d*)$')
    if major then
      major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch) or 0
      if major ~= emulated.major then
        return major < emulated.major and 1 or 0
      end
      if minor ~= emulated.minor then
        return minor < emulated.minor and 1 or 0
      end
      return patch <= emulated.patch and 1 or 0
    end
    local os_name = vim.uv.os_uname().sysname
    local is_windows = os_name:match('Windows') ~= nil
    local flags = {
      unix = not is_windows,
      win32 = is_windows,
      win64 = is_windows,
      win16 = false,
      mac = os_name == 'Darwin',
      macunix = os_name == 'Darwin',
      linux = os_name == 'Linux',
      eval = true,
      ttyin = true,
      ttyout = true,
      gui = false,
      gui_running = false,
      clipboard = false,
      python = false,
      python3 = false,
      vim9script = false,
      job = true,
      channel = true,
      timers = true,
      nvim_exec2 = true,
      rightleft = false,
      signcolumn = true,
    }
    local value = flags[feature]
    return value and 1 or 0
  end

  local builtin_commands = {}
  for _, name in ipairs({
    'edit', 'e', 'write', 'w', 'wq', 'x', 'xit', 'quit', 'q', 'qa', 'qall',
    'set', 'setlocal', 'let', 'lua', 'echo', 'silent', 'enew', 'source', 'so',
    'runtime', 'ru', 'autocmd', 'au', 'augroup', 'aug', 'highlight', 'hi',
    'syntax', 'syn', 'colorscheme', 'colo', 'map', 'nmap', 'vmap', 'imap',
    'nnoremap', 'vnoremap', 'inoremap', 'command', 'delcommand', 'normal',
    'buffer', 'b', 'bnext', 'bn', 'bprev', 'bp', 'bdelete', 'bd', 'split',
    'sp', 'vsplit', 'vsp', 'tabnew', 'tabedit', 'tabnext', 'tabprevious',
    'close', 'packadd', 'lcd', 'cd', 'pwd', 'version', 'help', 'messages',
  }) do
    builtin_commands[name] = true
  end

  local function vvar_exists(name)
    return vim.v[name] ~= nil and 1 or 0
  end

  function vim.fn.exists(expr)
    expr = tostring(expr)
    local kind, rest = expr:sub(1, 1), expr:sub(2)
    if kind == '*' then
      return vim.fn[rest] ~= nil and 1 or 0
    elseif kind == '&' then
      return option_defaults[rest] ~= nil and 1 or 0
    elseif kind == ':' then
      return builtin_commands[rest] and 2 or 0
    elseif kind == '$' then
      return os.getenv(rest) ~= nil and 1 or 0
    elseif kind == '#' then
      return 0
    elseif kind == 'g' and rest:sub(1, 1) == ':' then
      return vim.g[rest:sub(2)] ~= nil and 1 or 0
    elseif kind == 'b' and rest:sub(1, 1) == ':' then
      return vim.b[rest:sub(2)] ~= nil and 1 or 0
    elseif kind == 'w' and rest:sub(1, 1) == ':' then
      return vim.w[rest:sub(2)] ~= nil and 1 or 0
    elseif kind == 't' and rest:sub(1, 1) == ':' then
      return vim.t[rest:sub(2)] ~= nil and 1 or 0
    elseif kind == 'v' and rest:sub(1, 1) == ':' then
      return vvar_exists(rest:sub(2))
    end
    return vim.fn[expr] ~= nil and 1 or 0
  end

  function vim.fn.mode(expr)
    local mode = vim.api.nvim_get_mode().mode
    if expr == 1 then
      return mode
    end
    return mode
  end

  function vim.fn.visualmode(...)
    return 'v'
  end

  function vim.fn.winnr(...)
    return 1
  end

  function vim.fn.tabpagenr(...)
    return 1
  end

  function vim.fn.bufwinnr(buf)
    buf = vim.fn.bufnr(buf)
    return buf == vim.api.nvim_get_current_buf() and 1 or -1
  end

  function vim.fn.winheight(win)
    return vim.api.nvim_win_get_height(win or 0)
  end

  function vim.fn.winwidth(win)
    return vim.api.nvim_win_get_width(win or 0)
  end

  function vim.fn.expandcmd(expr)
    return vim.fn.expand(expr)
  end
end

-- ------------------------------------------------- vim.fn file and shell API
do
  local function glob_match(pattern, name)
    local regex = pattern:gsub('([%^%$%(%)%%%.%[%]%+%-])', '%%%1')
    regex = regex:gsub('%*', '.*'):gsub('%?', '.')
    return name:match('^' .. regex .. '$') ~= nil
  end

  function vim.fn.readfile(path, kind, max)
    path = tostring(path)
    local f = io.open(path, 'rb')
    if not f then
      api_error("Vim:E484: Can't open file " .. path)
    end
    local data = f:read('*a') or ''
    f:close()
    if kind == 'b' then
      local bytes = {}
      for i = 1, #data do
        bytes[#bytes + 1] = data:byte(i)
      end
      return bytes
    end
    local lines = {}
    for line in data:gmatch('([^\n]*)\n') do
      lines[#lines + 1] = line:gsub('\r$', '')
    end
    if data ~= '' and data:sub(-1) ~= '\n' then
      lines[#lines + 1] = data:match('([^\n]*)$'):gsub('\r$', '')
    end
    if max and max > 0 and #lines > max then
      while #lines > max do
        lines[#lines] = nil
      end
    end
    return lines
  end

  function vim.fn.writefile(lines, path, flags)
    path = tostring(path)
    local mode = 'w'
    if flags and flags:find('a') then
      mode = 'a'
    end
    local f = io.open(path, mode .. 'b')
    if not f then
      api_error("Vim:E482: Can't open file for writing: " .. path)
    end
    if #lines == 0 then
      f:write('')
    elseif flags and flags:find('b') then
      local bytes = {}
      for _, value in ipairs(lines) do
        bytes[#bytes + 1] = string.char(value)
      end
      f:write(table.concat(bytes))
    else
      f:write(table.concat(lines, '\n') .. '\n')
    end
    f:close()
    return 0
  end

  function vim.fn.glob(pattern, nosuf, list)
    pattern = tostring(pattern)
    local dir, base = pattern:match('^(.-)([^/]*)$')
    if dir == '' then
      dir = '.'
    end
    local entries = vim.uv._scandir_list(dir) or {}
    local matches = {}
    for _, name in ipairs(entries) do
      if glob_match(base, name) then
        local full
        if dir == '/' then
          full = '/' .. name
        elseif dir:sub(-1) == '/' then
          full = dir .. name
        else
          full = dir .. '/' .. name
        end
        matches[#matches + 1] = full
      end
    end
    table.sort(matches)
    if list then
      return matches
    end
    return table.concat(matches, '\n')
  end

  function vim.fn.globpath(paths, pattern, ...)
    local matches = {}
    for dir in tostring(paths):gmatch('[^,]+') do
      local found = vim.fn.glob(dir .. '/' .. pattern)
      if found ~= '' then
        for line in found:gmatch('[^\n]+') do
          matches[#matches + 1] = line
        end
      end
    end
    return table.concat(matches, '\n')
  end

  function vim.fn.simplify(path)
    path = tostring(path)
    local absolute = path:sub(1, 1) == '/'
    local parts = {}
    for part in path:gmatch('[^/]+') do
      if part == '.' then
        -- skip
      elseif part == '..' then
        if #parts > 0 and parts[#parts] ~= '..' then
          parts[#parts] = nil
        elseif not absolute then
          parts[#parts + 1] = '..'
        end
      else
        parts[#parts + 1] = part
      end
    end
    local out = table.concat(parts, '/')
    if absolute then
      out = '/' .. out
    end
    if out == '' then
      return absolute and '/' or '.'
    end
    return out
  end

  function vim.fn.pathshorten(path, length)
    path = tostring(path)
    length = tonumber(length) or 1
    local absolute = path:sub(1, 1) == '/'
    local parts = {}
    for part in path:gmatch('[^/]+') do
      parts[#parts + 1] = part
    end
    local out = {}
    for i, part in ipairs(parts) do
      if i < #parts then
        out[i] = part:sub(1, length)
      else
        out[i] = part
      end
    end
    return (absolute and '/' or '') .. table.concat(out, '/')
  end

  function vim.fn.resolve(path)
    path = tostring(path)
    return vim.uv.fs_realpath(path) or path
  end

  function vim.fn.tempname()
    return os.tmpname()
  end

  function vim.fn.delete(path, flags)
    path = tostring(path)
    flags = flags or ''
    if flags:find('d') or flags:find('r') then
      local command
      if vim.uv.os_uname().sysname:match('Windows') then
        command = 'rmdir /s /q "' .. path .. '" 2>nul'
      else
        command = "rm -rf '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null"
      end
      local ok = os.execute(command)
      return (ok == true or ok == 0) and 0 or -1
    end
    local ok = os.remove(path)
    return ok and 0 or -1
  end

  function vim.fn.rename(from, to)
    local ok = os.rename(tostring(from), tostring(to))
    return ok and 0 or -1
  end

  local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
  end

  -- Accepts a command string or an argv list (like Neovim), merges stderr
  -- into the output and records the exit status in v:shell_error.
  function vim.fn.system(cmd, _input)
    local command
    if type(cmd) == 'table' then
      local parts = {}
      for i, arg in ipairs(cmd) do
        parts[i] = shell_quote(arg)
      end
      command = table.concat(parts, ' ')
    else
      command = tostring(cmd)
    end
    local handle = io.popen('(' .. command .. ') 2>&1; echo "__ZIGVIM_RC__$?"')
    if not handle then
      vvars.shell_error = 1
      return ''
    end
    local raw = handle:read('*a') or ''
    handle:close()
    local output, status = raw:match('^(.*)__ZIGVIM_RC__(%d+)%s*$')
    if not output then
      vvars.shell_error = 0
      return raw
    end
    vvars.shell_error = tonumber(status) or 0
    return output
  end

  function vim.fn.systemlist(cmd)
    local output = vim.fn.system(cmd)
    local list = {}
    for line in output:gmatch('([^\n]*)\n') do
      list[#list + 1] = line
    end
    if output ~= '' and output:sub(-1) ~= '\n' then
      list[#list + 1] = output:match('([^\n]*)$')
    end
    return list
  end

  function vim.fn.reg_executing()
    return ''
  end

  function vim.fn.reg_recording()
    return ''
  end

  function vim.fn.histadd(kind, item)
    return 1
  end

  local quickfix = {}
  local quickfix_title = ''

  function vim.fn.setqflist(list, ...)
    quickfix = vim.deepcopy(list or {})
    quickfix_title = ':setqflist()'
    return 0
  end

  function vim.fn.getqflist(opts)
    if type(opts) == 'table' and opts.title ~= nil then
      return { title = quickfix_title }
    end
    local out = {}
    for i, item in ipairs(quickfix) do
      out[i] = {
        bufnr = item.bufnr or 0,
        lnum = item.lnum or 0,
        end_lnum = item.end_lnum or 0,
        col = item.col or 0,
        end_col = item.end_col or 0,
        text = item.text or '',
        type = item.type or '',
        nr = item.nr or 0,
        valid = 1,
        pattern = item.pattern or '',
        module = item.module or '',
        vcol = 0,
      }
    end
    return out
  end
end

-- ------------------------------------------- filetype detection and plugins
-- Neovim turns on filetype detection, filetype plugins, indent plugins and
-- syntax at startup (runtime/filetype.lua, ftplugin.vim, indent.vim,
-- syntax/syntax.vim). zigvim has no Vimscript engine, so the same startup
-- state and events are created here; Lua ftplugins/indent files are sourced
-- with :runtime semantics, the .vim ones are covered by the stub register.
local function source_ft_lua(subdir, name, filename)
  local chunk, err = loadfile(filename)
  if not chunk then
    error(err, 0)
  end
  chunk()
end

local function load_ft_files(subdir, name)
  for _, dir in ipairs(list_get('runtimepath')) do
    local base = dir .. '/' .. subdir
    local exact = base .. '/' .. name .. '.lua'
    if vim.uv.fs_stat(exact) then
      source_ft_lua(subdir, name, exact)
    end
    local entries = vim.uv._scandir_list(base) or {}
    table.sort(entries)
    for _, entry in ipairs(entries) do
      if entry:sub(1, #name + 1) == name .. '_' and entry:match('%.lua$') then
        source_ft_lua(subdir, name, base .. '/' .. entry)
      end
    end
    local nested = base .. '/' .. name
    local nested_entries = vim.uv._scandir_list(nested) or {}
    table.sort(nested_entries)
    for _, entry in ipairs(nested_entries) do
      if entry:match('%.lua$') then
        source_ft_lua(subdir, name, nested .. '/' .. entry)
      end
    end
  end
end

local function load_ftplugin()
  local ft = vim.bo.filetype
  if ft == '' then
    return
  end
  local undo = vim.b.undo_ftplugin
  if undo and undo ~= '' then
    pcall(exec_cmd, undo)
  end
  vim.b.undo_ftplugin = nil
  vim.b.did_ftplugin = nil
  for name in ft:gmatch('[^.]+') do
    load_ft_files('ftplugin', name)
  end
end

local function load_indent()
  local ft = vim.bo.filetype
  if ft == '' then
    return
  end
  local undo = vim.b.undo_indent
  if undo and undo ~= '' then
    pcall(exec_cmd, undo)
  end
  vim.b.undo_indent = nil
  vim.b.did_indent = nil
  for name in ft:gmatch('[^.]+') do
    load_ft_files('indent', name)
  end
end

local function set_syntax_from_filetype()
  if vim.b.ts_highlight then
    return
  end
  local ft = vim.bo.filetype
  if ft ~= '' then
    vim.bo.syntax = ft
  end
end

function vim._setup_filetype()
  if not vim.g.did_load_filetypes then
    vim.g.did_load_filetypes = 1
    vim.api.nvim_create_augroup('filetypedetect', { clear = false })
    local function detect(ev)
      if not vim.api.nvim_buf_is_valid(ev.buf) then
        return
      end
      local ft, on_detect = vim.filetype.match({ filename = ev.file, buf = ev.buf })
      if not ft then
        return
      end
      if on_detect then
        on_detect(ev.buf)
      end
      vim.api.nvim_buf_call(ev.buf, function()
        vim.bo.filetype = ft
      end)
    end
    vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile', 'StdinReadPost' }, {
      group = 'filetypedetect',
      pattern = '*',
      callback = detect,
    })
    if not vim.g.ft_ignore_pat then
      vim.g.ft_ignore_pat = '\\.\\(Z\\|gz\\|bz2\\|zip\\|tgz\\)$'
    end
    -- Lua filetype detection plugins (`ftdetect/*.lua`), in runtimepath order.
    for _, file in ipairs(vim.api.nvim_get_runtime_file('ftdetect/*.lua', true)) do
      local chunk = loadfile(file)
      if chunk then
        chunk()
      end
    end
  end

  if not vim.g.did_load_ftplugin then
    vim.g.did_load_ftplugin = 1
    local group = vim.api.nvim_create_augroup('filetypeplugin', { clear = false })
    vim.api.nvim_create_autocmd('FileType', { group = group, pattern = '*', callback = load_ftplugin })
  end

  if not vim.g.did_indent_on then
    vim.g.did_indent_on = 1
    local group = vim.api.nvim_create_augroup('filetypeindent', { clear = false })
    vim.api.nvim_create_autocmd('FileType', { group = group, pattern = '*', callback = load_indent })
  end

  if not vim.g.syntax_on then
    vim.g.syntax_on = 1
    local group = vim.api.nvim_create_augroup('syntaxset', { clear = false })
    vim.api.nvim_create_autocmd('FileType', { group = group, pattern = '*', callback = set_syntax_from_filetype })
  end
end

-- Load Neovim's default commands, mappings, and augroups
-- This creates Inspect, InspectTree, EditQuery, Open commands and
-- nvim.cmdwin, nvim.popupmenu, nvim.swapfile, nvim.terminal augroups
local ok_defaults, err_defaults = pcall(require, 'vim._core.defaults')
if not ok_defaults then
  io.stderr:write('Warning: failed to load vim._core.defaults: ' .. tostring(err_defaults) .. '\n')
end

-- Runtime plugins that Neovim ships as Vimscript, reimplemented in Lua.
-- matchit.vim: mappings plus the MatchEnable/MatchDisable/MatchDebug commands.
local ok_matchit, matchit_stub = pcall(require, 'vim._matchit_stub')
if ok_matchit then
  vim.g.loaded_matchit = 1
  matchit_stub.define_commands()
  matchit_stub.setup()
else
  io.stderr:write('Warning: failed to load vim._matchit_stub: ' .. tostring(matchit_stub) .. '\n')
end

-- matchparen.vim: the matchparen augroup and :DoMatchParen/:NoMatchParen.
local ok_matchparen, matchparen = pcall(require, 'vim._matchparen')
if ok_matchparen then
  matchparen.setup()
else
  io.stderr:write('Warning: failed to load vim._matchparen: ' .. tostring(matchparen) .. '\n')
end

-- netrw: directory browsing plus the :Explore/:N* commands and Network group.
local ok_netrw, netrw = pcall(require, 'vim._netrw')
if ok_netrw then
  netrw.setup()
else
  io.stderr:write('Warning: failed to load vim._netrw: ' .. tostring(netrw) .. '\n')
end

-- gzip.vim / tarPlugin.vim / zipPlugin.vim: compressed files and archives.
local ok_archives, archives = pcall(require, 'vim._archives')
if ok_archives then
  archives.setup()
else
  io.stderr:write('Warning: failed to load vim._archives: ' .. tostring(archives) .. '\n')
end
