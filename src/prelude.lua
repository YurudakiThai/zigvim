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

-- Like Neovim's cjson: a table with only positive integer keys is an array (holes
-- become null) if its highest index is <= 10 or <= 2 * its entry count; sparser
-- than that is an error. Returns the array length, or nil for an object.
local function is_array(t)
  local max, count = 0, 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then
      return nil
    end
    max, count = math.max(max, k), count + 1
  end
  if max == 0 then
    return nil
  end
  if max > 10 and max > 2 * count then
    error('Cannot serialise table: excessively sparse array', 0)
  end
  return max
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
    if next(v) == nil then
      return '[]' -- like Neovim: only vim.empty_dict() encodes as {}
    end
    local parts = {}
    local len = is_array(v)
    if len then
      for i = 1, len do
        parts[i] = v[i] == nil and 'null' or encode_value(v[i])
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
              cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
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
-- vim.version is the runtime module (lazy-loaded); it reads the version from
-- api_info(), which reports the Neovim release zigvim is tested against.
function vim.fn.api_info()
  return {
    version = {
      major = 0, minor = 12, patch = 6, api_level = 14, api_compatible = 0,
      api_prerelease = false, prerelease = false, build = vim.NIL,
    },
  }
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

-- Message history for :messages (Neovim keeps nvim_echo(history=true), notify,
-- errors and editor messages such as the undo summary). shortcut: 200 entries.
vim._msg_history = {}
function vim._msg_save(text)
  local h = vim._msg_history
  h[#h + 1] = text
  if #h > 200 then
    table.remove(h, 1)
  end
end

-- Neovim's default vim.notify: an nvim_echo with history, error-highlighted for ERROR.
function vim.notify(msg, level, opts)
  level = level or vim.log.levels.INFO
  if level == vim.log.levels.ERROR then
    vim.api.nvim_echo({ { tostring(msg) } }, true, { err = true })
  elseif level == vim.log.levels.WARN then
    vim.api.nvim_echo({ { tostring(msg), 'WarningMsg' } }, true, {})
  else
    vim.api.nvim_echo({ { tostring(msg) } }, true, {})
  end
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

-- vim.opt.<boolean/number option> is an Option object too; :get() returns the value.
local ScalarOption = {}
ScalarOption.__index = ScalarOption
function ScalarOption:get()
  return option_mt.__index(nil, self._name)
end

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
    elseif value ~= nil then
      return setmetatable({ _name = option_aliases[k] or k }, ScalarOption)
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
  __index = function(t, k)
    -- vim.wo[winid] and vim.wo[winid][bufnr]
    -- shortcut: one set of window options shared by all windows, upgrade with per-window options.
    if type(k) == 'number' then
      return t
    end
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
-- Bumped whenever something drawn changes outside a keypress (extmarks, explicit
-- redraws); the TUI redraws on its idle tick when it moved.
vim._ui_gen = 0

function vim.api.nvim__redraw(_)
  vim._ui_gen = vim._ui_gen + 1
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

-- Run `fn` on the main loop, soon. Neovim schedules this on its event loop;
-- a zero-delay libuv timer has the same effect here.
function vim.schedule(fn)
  vim.defer_fn(fn, 0)
end

-- Wrap a callback so it is invoked through vim.schedule(). Plugins use this
-- for callbacks coming from libuv handles and jobs.
function vim.schedule_wrap(fn)
  return function(...)
    local args = { ... }
    return vim.schedule(function()
      return fn(unpack(args))
    end)
  end
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

-- shortcut: one global cwd (no window/tab-local :lcd/:tcd) and no DirChanged event.
function vim.fn.chdir(dir)
  local old = vim.uv.cwd()
  if not vim.uv.chdir(vim.fn.expand(tostring(dir))) then
    error('Vim:E344: Can\'t find directory "' .. tostring(dir) .. '" in cdpath', 0)
  end
  return old
end

vim.api.nvim_set_current_dir = function(dir)
  if not vim.uv.chdir(vim.fn.expand(tostring(dir))) then
    error('Failed to change directory', 0)
  end
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
    for lnum = math.min(start[2], finish[2]), math.max(start[2], finish[2]) do
      regions[#regions + 1] = { { buf, lnum, 1, 0 }, { buf, lnum, line_length(lnum), 0 } }
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
  -- One region per line. An exclusive end steps back one character (to the end of
  -- the previous line from column 1); a zero-width range stays one character.
  local end_lnum, endcol = to[2], to[3]
  if exclusive and not (from[2] == to[2] and from[3] == to[3]) then
    if endcol > 1 then
      endcol = endcol - 1
      local line = lines[end_lnum] or ''
      while endcol > 1 and (line:byte(endcol) or 0) >= 0x80 and line:byte(endcol) < 0xC0 do
        endcol = endcol - 1
      end
    elseif end_lnum > from[2] then
      end_lnum = end_lnum - 1
      endcol = line_length(end_lnum)
    end
  end
  for lnum = from[2], end_lnum do
    local first = lnum == from[2] and from[3] or 1
    if not opts.eol then
      first = math.min(first, line_length(lnum)) -- an empty line gives column 0
    end
    local last = lnum == end_lnum and math.min(endcol, line_length(lnum)) or line_length(lnum)
    regions[#regions + 1] = { { buf, lnum, first, 0 }, { buf, lnum, last, 0 } }
  end
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

-- shortcut: topline/leftcol are not tracked by the API layer, so the view only carries
-- the cursor. Upgrade when windows expose scroll state.
function vim.fn.winsaveview()
  local pos = vim.api.nvim_win_get_cursor(0)
  return {
    lnum = pos[1],
    col = pos[2],
    coladd = 0,
    curswant = pos[2],
    topline = 1,
    topfill = 0,
    leftcol = 0,
    skipcol = 0,
  }
end

function vim.fn.winrestview(view)
  if type(view) == 'table' and view.lnum then
    vim.api.nvim_win_set_cursor(0, { view.lnum, view.col or 0 })
  end
end

-- Keys fed while the TUI runs go to its typeahead (vim._tui_feed); with no UI
-- (headless) there is no input loop to receive them, so they are dropped.
function vim.api.nvim_feedkeys(keys, mode, _escape_ks)
  if vim._tui_feed then
    vim._tui_feed(keys, mode or '')
  end
end

function vim.fn.feedkeys(keys, mode)
  vim.api.nvim_feedkeys(keys, mode or '', false)
  return 0
end

-- vim.on_key: register a callback for key presses. Returns a namespace ID.
-- Currently a stub that doesn't actually call the callbacks (no key event system yet).
local _on_key_ns = 0
function vim.on_key(fn, ns_id)
  if ns_id == 0 or ns_id == nil then
    _on_key_ns = _on_key_ns + 1
    ns_id = _on_key_ns
  end
  -- TODO: actually register the callback and call it on key presses
  return ns_id
end

function vim.fn.getftime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime and stat.mtime.sec or -1
end

function vim.fn.getfsize(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.size or -1
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
  -- Neovim writes a trailing newline when 'endofline' is set (default true).
  -- For a truly new, never-modified empty buffer Neovim writes 0 bytes, but
  -- distinguishing that requires tracking buffer-creation state.  The practical
  -- rule used by the test suite and by most workflows: always emit the final
  -- newline so that 'a\n' with the 'a' deleted still writes '\n'.
  local body
  if #lines == 0 then
    body = ''
  elseif #lines == 1 and lines[1] == '' and not vim.bo.modified then
    -- Truly empty, never-modified buffer: write 0 bytes (matches nvim :enew + :w).
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
  -- Neovim's order: BufReadPre, read, BufReadPost (FileType) -- or BufNewFile for a
  -- missing file -- then BufEnter, BufWinEnter; for the file given on the command
  -- line BufWinEnter comes first and startup fires BufEnter.
  -- shortcut: the current buffer is reused, so there is no BufNew/BufAdd.
  local lines = read_file(full)
  vim.api.nvim_buf_set_name(0, path)
  if lines then
    fire_autocmd('BufReadPre', {buffer = 0})
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or { '' })
  vim._buf_set_modified(0, false)
  fire_autocmd(lines and 'BufReadPost' or 'BufNewFile', {buffer = 0})
  if vim._startup_edit then
    vim._startup_edit = nil
    fire_autocmd('BufWinEnter', {buffer = 0})
    return
  end
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

  -- `cmd | cmd`: split on a bar outside quotes, except for commands that take the
  -- rest of the line (Vim's :bar list). shortcut: no `\|` escape handling beyond that.
  local takes_bar = {
    lua = true, luado = true, normal = true, ['normal!'] = true, norm = true, ['norm!'] = true,
    command = true, ['command!'] = true, ['!'] = true, global = true, g = true,
  }
  if not takes_bar[name] and not name:match('map$') and not name:match('^[nvxsoilct]?noremap$')
    and not ((name == 'autocmd' or name == 'au') and rest:match('%S+%s+%S+%s+%S')) then
    local quote
    for i = 1, #cmd do
      local ch = cmd:sub(i, i)
      if quote then
        if ch == quote and cmd:sub(i - 1, i - 1) ~= '\\' then
          quote = nil
        end
      elseif (ch == '"' or ch == "'") and (name == 'exe' or name == 'execute' or name == 'echo' or name == 'let') then
        quote = ch
      elseif ch == '|' and cmd:sub(i - 1, i - 1) ~= '\\' then
        exec_cmd(cmd:sub(1, i - 1))
        return exec_cmd(cmd:sub(i + 1))
      end
    end
  end

  if name == 'silent' or name == 'silent!' then
    exec_cmd(rest)
  elseif name == 'augroup' or name == 'aug' or name == 'augroup!' or name == 'aug!' then
    -- :augroup {name} sets the group later :autocmd lines go to; END resets it.
    if name:sub(-1) == '!' then
      pcall(vim.api.nvim_del_augroup_by_name, rest)
    elseif rest:upper() == 'END' then
      vim._cur_augroup = nil
    elseif rest ~= '' then
      vim.api.nvim_create_augroup(rest, { clear = false })
      vim._cur_augroup = rest
    end
  elseif name == 'exe' or name == 'execute' or name == 'exec' then
    exec_cmd(tostring(vim.api.nvim_eval(rest)))
  elseif name == 'messages' or name == 'mes' then
    if #vim._msg_history > 0 then
      vim._out(table.concat(vim._msg_history, '\n') .. '\n')
    end
  elseif name == 'normal' or name == 'normal!' or name == 'norm' or name == 'norm!' then
    -- shortcut: only runs while the TUI is active; headless :normal is a no-op.
    if vim._tui_normal then
      vim._tui_normal(rest, name:sub(-1) == '!')
    end
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
  elseif name == 'map' or name == 'nmap' or name == 'vmap' or name == 'xmap'
    or name == 'omap' or name == 'imap' or name == 'cmap' or name == 'tmap'
    or name == 'noremap' or name == 'nnoremap' or name == 'vnoremap'
    or name == 'xnoremap' or name == 'onoremap' or name == 'inoremap'
    or name == 'cnoremap' or name == 'tnoremap' then
    -- Parse mapping commands: map, nmap, nnoremap, etc.
    local mode_map = {
      map = '', nmap = 'n', vmap = 'v', xmap = 'x',
      omap = 'o', imap = 'i', cmap = 'c', tmap = 't',
      noremap = '', nnoremap = 'n', vnoremap = 'v', xnoremap = 'x',
      onoremap = 'o', inoremap = 'i', cnoremap = 'c', tnoremap = 't',
    }
    local noremap = name:match('noremap') ~= nil
    local mode = mode_map[name] or ''
    local lhs, rhs = rest:match('^(%S+)%s+(.*)$')
    if lhs and rhs then
      vim.api.nvim_set_keymap(mode, lhs, rhs, { noremap = noremap, silent = false })
    end
  elseif name == 'unmap' or name == 'nunmap' or name == 'vunmap' or name == 'xunmap'
    or name == 'ounmap' or name == 'iunmap' or name == 'cunmap' or name == 'tunmap'
    or name == 'mapclear' or name == 'nmapclear' or name == 'vmapclear'
    or name == 'xmapclear' or name == 'omapclear' or name == 'imapclear'
    or name == 'cmapclear' or name == 'tmapclear' then
    -- Unmap commands: accepted but not fully implemented (would need to iterate and delete)
  elseif name == 'packadd' or name == 'filetype'
    or name == 'syntax' or name == 'syn'
    or name == 'menu' or name == 'amenu' or name == 'nmenu' or name == 'vmenu'
    or name == 'imenu' or name == 'cmenu' or name == 'omenu' or name == 'tmenu'
    or name == 'noremenu' or name == 'anoremenu' or name == 'nnoremenu'
    or name == 'vnoremenu' or name == 'inoremenu' or name == 'cnoremenu'
    or name == 'onoremenu' or name == 'tnoremenu'
    or name == 'unmenu' or name == 'aunmenu' then
    -- Accepted and ignored: no Vimscript engine / highlighter / menu system behind these yet.
  elseif name == 'autocmd' or name == 'au' or name == 'autocmd!' or name == 'au!' then
    vim._ex_autocmd(name:sub(-1) == '!', rest)
  elseif name == 'cd' or name == 'lcd' or name == 'tcd' or name == 'chdir' then
    vim.fn.chdir(rest == '' and vim.env.HOME or rest)
  elseif name == 'noh' or name == 'nohlsearch' or name == 'redraw' or name == 'redraw!' then
    -- nothing to do: the TUI redraws after every key and draws no search highlight
  elseif name == 'lsp' then
    require('vim._core.ex_cmd').ex_lsp(rest)
  elseif name == 'highlight' or name == 'hi' or name == 'highlight!' or name == 'hi!' then
    vim._hl_command(name:sub(-1) == '!', rest)
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
    -- shortcut: plain `=` into g:/b:/w:/t:/v: only (no +=, unpacking, options or registers).
    local scope, var, expr = rest:match('^([gbwtv]):([%w_#]+)%s*=%s*(.*)$')
    if not scope then
      error('E121: Undefined variable: ' .. tostring(rest:match('^(%S+)')))
    end
    vim[scope][var] = vim.api.nvim_eval(expr)
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
    vim._out(tostring(vim.api.nvim_eval(rest)) .. '\n')
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
  return '' -- Neovim's vim.cmd returns the (empty, uncaptured) output
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

-- Command output (:echo, :autocmd listings) goes through vim._out so
-- nvim_exec2({output = true}) can capture it.
local out_stack = {}
function vim._out(text)
  local top = out_stack[#out_stack]
  if top then
    top[#top + 1] = text
  elseif vim._tui_msg then
    vim._tui_msg((text:gsub('\n$', '')), false)
  else
    io.stdout:write(text)
  end
end

vim.api.nvim_exec2 = function(src, opts)
  if not (opts and opts.output) then
    exec_lines(src, false)
    return vim.empty_dict()
  end
  out_stack[#out_stack + 1] = {}
  local ok, e = pcall(exec_lines, src, false)
  local captured = table.remove(out_stack)
  if not ok then
    error(e, 0)
  end
  return { output = (table.concat(captured):gsub('\n$', '')) }
end

-- Deprecated, still used (lualine): returns the output when {output} is true, else ''.
vim.api.nvim_exec = function(src, output)
  return output and vim.api.nvim_exec2(src, { output = true }).output or (vim.api.nvim_exec2(src, {}) and '')
end

vim.api.nvim_exec_lua = function(code, args)
  return exec_lua(code, args)
end

-- Buffers made by bufadd() stay unloaded (no lines) until bufload().
-- shortcut: bufload() fires no BufRead autocommands.
local unloaded_bufs = {}
vim.api.nvim_buf_is_loaded = function(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  return vim.api.nvim_buf_is_valid(buf) and not unloaded_bufs[buf]
end
do
  local raw_line_count = vim.api.nvim_buf_line_count
  vim.api.nvim_buf_line_count = function(buf)
    local id = buf == 0 and vim.api.nvim_get_current_buf() or buf
    if unloaded_bufs[id] then
      return 0
    end
    return raw_line_count(buf)
  end
end

local function full_buf_name(name)
  local abs = vim.fn.fnamemodify(name, ':p')
  local dir, base = abs:match('^(.*)/([^/]*)$')
  local real = dir and vim.uv.fs_realpath(dir ~= '' and dir or '/')
  return real and (real:gsub('/$', '') .. '/' .. base) or abs
end

function vim.fn.bufadd(name)
  name = tostring(name)
  if name ~= '' then
    local full = full_buf_name(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == full then
        return b
      end
    end
    name = full
  end
  local b = vim.api.nvim_create_buf(false, false)
  if name ~= '' then
    vim.api.nvim_buf_set_name(b, name)
  end
  unloaded_bufs[b] = true
  return b
end

function vim.fn.bufload(buf)
  local b = vim.fn.bufnr(buf)
  if b > 0 and unloaded_bufs[b] then
    unloaded_bufs[b] = nil
    local name = vim.api.nvim_buf_get_name(b)
    local f = name ~= '' and io.open(name, 'rb')
    if f then
      local data = f:read('*a')
      f:close()
      local lines = vim.split(data, '\n', { plain = true })
      if lines[#lines] == '' and #lines > 1 then
        lines[#lines] = nil
      end
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
      vim._buf_set_modified(b, false)
    end
  end
  return 0
end

-- vim.str_utf_start / str_utf_end / str_utf_pos (C in Neovim): offsets from the
-- 1-based byte {index} to the first / last byte of the character holding it.
local function utf_check(s, index)
  if type(index) ~= 'number' or index < 1 or index > #s then
    error('index out of range', 2)
  end
end
function vim.str_utf_start(s, index)
  utf_check(s, index)
  local i = index
  while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do
    i = i - 1
  end
  return i - index
end
function vim.str_utf_end(s, index)
  utf_check(s, index)
  local start = index + vim.str_utf_start(s, index)
  local ch = s:match('^[%z\1-\127\194-\244][\128-\191]*', start) or s:sub(start, start)
  return start + #ch - 1 - index
end
function vim.str_utf_pos(s)
  local out = {}
  for start in s:gmatch('()[%z\1-\127\194-\244][\128-\191]*') do
    out[#out + 1] = start
  end
  return out
end

-- The C side only allocates the buffer; apply nvim_create_buf's {listed} and {scratch}.
local create_buf = vim.api.nvim_create_buf
vim.api.nvim_create_buf = function(listed, scratch)
  local buf = create_buf(listed, scratch)
  if buf and buf > 0 then
    vim.bo[buf].buflisted = listed and true or false
    if scratch then
      vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'hide', false
    end
  end
  return buf
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

-- Like Neovim: a callback error is reported, not raised into the edit, and a
-- callback returning true detaches.
local function fire_buf_attach(buf, firstline, lastline, new_lastline, byte_count)
  local callbacks = buffer_attach_callbacks[buf]
  if not callbacks then
    return
  end
  for i = #callbacks, 1, -1 do
    local opts = callbacks[i]
    if opts.on_lines then
      local tick = vim.api.nvim_buf_get_changedtick and vim.api.nvim_buf_get_changedtick(buf) or 0
      local ok, res = pcall(opts.on_lines, 'lines', buf, tick, firstline, lastline, new_lastline, byte_count or 0)
      if not ok then
        vim.notify('Error in on_lines callback: ' .. tostring(res), vim.log.levels.ERROR)
      elseif res == true then
        table.remove(callbacks, i)
      end
    end
  end
end

-- on_bytes(…, start_row, start_col, start_byte, old_end_row, old_end_col, old_end_byte,
-- new_end_row, new_end_col, new_end_byte) for every attached on_bytes callback.
local function fire_buf_bytes(buf, ...)
  local callbacks = buffer_attach_callbacks[buf]
  if not callbacks then
    return
  end
  for i = #callbacks, 1, -1 do
    local opts = callbacks[i]
    if opts.on_bytes then
      local tick = vim.api.nvim_buf_get_changedtick and vim.api.nvim_buf_get_changedtick(buf) or 0
      local ok, res = pcall(opts.on_bytes, 'bytes', buf, tick, ...)
      if not ok then
        vim.notify('Error in on_bytes callback: ' .. tostring(res), vim.log.levels.ERROR)
      elseif res == true then
        table.remove(callbacks, i)
      end
    end
  end
end

-- Bytes before 0-based `row`, newlines included (only computed when someone listens).
local function byte_offset(buf, row)
  local n = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, row, false)) do
    n = n + #l + 1
  end
  return n
end

local function has_on_bytes(buf)
  for _, opts in ipairs(buffer_attach_callbacks[buf] or {}) do
    if opts.on_bytes then
      return true
    end
  end
  return false
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
      -- Like Neovim: "" yields the dir itself; no doubled '/' (lazy.nvim feeds these back into rtp).
      local pattern = (sub == '' or dir:sub(-1) == '/') and dir .. sub or dir .. '/' .. sub
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

vim.api.nvim_echo = function(chunks, history, opts)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    parts[#parts + 1] = tostring(chunk[1])
  end
  local text = table.concat(parts)
  if history then
    vim._msg_save(text)
  end
  if vim._tui_msg then
    vim._tui_msg(text, opts and opts.err) -- the TUI's message line, not raw stdout
  else
    io.stderr:write(text .. '\n') -- Neovim headless writes messages to stderr
  end
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

-- exepath({name}): full path of an executable from $PATH (or {name} itself if it has a '/').
function vim.fn.exepath(name)
  name = tostring(name)
  if name == '' then
    return ''
  end
  if name:find('/', 1, true) then
    return vim.fn.executable(name) == 1 and vim.fn.fnamemodify(name, ':p') or ''
  end
  for dir in (os.getenv('PATH') or ''):gmatch('[^:]+') do
    local p = dir .. '/' .. name
    local st = vim.uv.fs_stat(p)
    if st and st.type == 'file' and vim.fn.executable(p) == 1 then
      return p
    end
  end
  return ''
end

-- Marks: buffer marks (a-z and specials) per buffer, file marks (A-Z) global.
-- shortcut: marks do not move when lines are inserted or deleted, and the TUI has
-- no m/'/` commands yet; '" and '. are reported at line 1 (Neovim tracks them).
do
  local buf_marks, file_marks = {}, {}
  local function bufnr(buf)
    return (buf == 0 or buf == nil) and vim.api.nvim_get_current_buf() or buf
  end
  local function check_name(name)
    if type(name) ~= 'string' or #name ~= 1 then
      api_error("Invalid mark name (must be a single char): '" .. tostring(name) .. "'")
    end
  end
  vim.api.nvim_buf_set_mark = function(buf, name, line, col, _opts)
    buf = bufnr(buf)
    check_name(name)
    if line < 1 or line > vim.api.nvim_buf_line_count(buf) then
      api_error("Invalid 'line': out of range")
    end
    if name:match('%u') then
      file_marks[name] = { buf, line, col }
    else
      buf_marks[buf] = buf_marks[buf] or {}
      buf_marks[buf][name] = { line, col }
    end
    return true
  end
  vim.api.nvim_buf_get_mark = function(buf, name)
    buf = bufnr(buf)
    check_name(name)
    if name:match('%u') then
      local m = file_marks[name]
      return (m and m[1] == buf) and { m[2], m[3] } or { 0, 0 }
    end
    local m = buf_marks[buf] and buf_marks[buf][name]
    return m and { m[1], m[2] } or { 0, 0 }
  end
  vim.api.nvim_buf_del_mark = function(buf, name)
    buf = bufnr(buf)
    check_name(name)
    local t = name:match('%u') and file_marks or buf_marks[buf]
    if t and t[name] then
      t[name] = nil
      return true
    end
    return false
  end
  function vim.fn.getmarklist(buf)
    local out = {}
    if buf == nil then
      for _, name in ipairs(vim.tbl_keys(file_marks)) do
        local m = file_marks[name]
        out[#out + 1] = { mark = "'" .. name, pos = { m[1], m[2], m[3] + 1, 0 }, file = vim.api.nvim_buf_get_name(m[1]) }
      end
      table.sort(out, function(x, y) return x.mark < y.mark end)
      return out
    end
    if type(buf) ~= 'number' or buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
      return out
    end
    local names = vim.tbl_keys(buf_marks[buf] or {})
    table.sort(names)
    for _, name in ipairs(names) do
      local m = buf_marks[buf][name]
      out[#out + 1] = { mark = "'" .. name, pos = { buf, m[1], m[2] + 1, 0 } }
    end
    out[#out + 1] = { mark = "'\"", pos = { buf, 1, 1, 0 } }
    if vim.bo[buf].modified then
      out[#out + 1] = { mark = "'.", pos = { buf, 1, 1, 0 } }
    end
    return out
  end
end

-- winbufnr({nr}): {nr} is 0, a window number or a window id; -1 if invalid.
function vim.fn.winbufnr(nr)
  nr = tonumber(nr) or -1
  if nr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  local wins = vim.api.nvim_list_wins()
  local win = wins[nr] or (vim.api.nvim_win_is_valid(nr) and nr) or nil
  return win and vim.api.nvim_win_get_buf(win) or -1
end

function vim.fn.win_findbuf(buf)
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_buf(w) == buf
  end, vim.api.nvim_list_wins())
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

-- luv returns times as { sec, nsec } tables; the Zig core returns only a number.
-- shortcut: atime/ctime/birthtime reuse mtime, and mode/uid/ino are absent; upgrade
-- when the core exposes the full struct stat.
do
  local core_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(path)
    local st = core_stat(path)
    if st and type(st.mtime) == 'number' then
      local sec = st.mtime
      st.mtime = { sec = sec, nsec = 0 }
      st.atime = { sec = sec, nsec = 0 }
      st.ctime = { sec = sec, nsec = 0 }
      st.birthtime = { sec = sec, nsec = 0 }
    end
    return st
  end
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
  ['<nl>'] = '<NL>', ['<NL>'] = '<NL>',
}
for n = 13, 37 do -- <F1>..<F12> are listed above
  special_key_names['<f' .. n .. '>'] = '<F' .. n .. '>'
end

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

-- keytrans: raw keys -> <> notation. zigvim's replace_termcodes already emits
-- canonical <...> tokens instead of Neovim's K_SPECIAL bytes, so those are kept.
-- shortcut: a literal "<CR>"-like text typed as plain chars is indistinguishable
-- from the key; fix together with byte-accurate replace_termcodes.
do
  local canonical = {}
  for _, v in pairs(special_key_names) do
    canonical[v] = true
  end
  -- Control keys that are the same byte as a named key.
  local same_byte = { ['<C-J>'] = '<NL>', ['<C-M>'] = '<CR>', ['<C-I>'] = '<Tab>', ['<C-[>'] = '<Esc>', ['<C-@>'] = '<Nul>', ['<C-?>'] = '' }
  local raw_names = { [' '] = '<Space>', ['<'] = '<lt>', ['\r'] = '<CR>', ['\n'] = '<NL>', ['\27'] = '<Esc>', ['\t'] = '<Tab>', ['\0'] = '<Nul>', ['\127'] = '' }
  function vim.fn.keytrans(s)
    s = tostring(s)
    local out, i = {}, 1
    while i <= #s do
      local tok = s:match('^<[^<>]+>', i)
      if tok and (canonical[tok] or tok:match('^<[CMSAD]%-.+>$') or tok:match('^<F%d+>$') or tok:match('^<[Pp]lug>')) then
        out[#out + 1] = same_byte[tok] or tok
        i = i + #tok
      else
        local ch = s:match('^[%z\1-\127\194-\244][\128-\191]*', i) or s:sub(i, i)
        local b = ch:byte()
        out[#out + 1] = raw_names[ch] or (b < 32 and '<C-' .. string.char(b + 64) .. '>') or ch
        i = i + #ch
      end
    end
    return table.concat(out)
  end
end

-- shortcut: providers are stored but never invoked; the TUI has no decoration redraw pass yet.
vim._decoration_providers = {}
function vim.api.nvim_set_decoration_provider(ns_id, opts)
  vim._decoration_providers[ns_id] = opts
end

local function nonblank(lnum, step)
  lnum = tonumber(lnum) or 0
  local n = vim.api.nvim_buf_line_count(0)
  if lnum < 1 or lnum > n then
    return 0
  end
  for l = lnum, step > 0 and n or 1, step do
    if vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]:find('%S') then
      return l
    end
  end
  return 0
end
function vim.fn.prevnonblank(lnum)
  return nonblank(lnum, -1)
end
function vim.fn.nextnonblank(lnum)
  return nonblank(lnum, 1)
end

-- :autocmd[!] [group] {events} {pat} [++once] [++nested] {cmd}
-- shortcut: no `<buffer>` patterns and no listing (`:autocmd` without a command).
function vim._ex_autocmd(bang, rest)
  local words = {}
  for w in rest:gmatch('%S+') do
    words[#words + 1] = w
  end
  local group
  if words[1] and pcall(vim.api.nvim_get_autocmds, { group = words[1] }) then
    group = table.remove(words, 1)
  end
  local explicit = group
  group = group or vim._cur_augroup
  local events, pat = words[1], words[2]
  local cmd = rest:match('^%s*' .. (explicit and vim.pesc(explicit) .. '%s+' or '') .. (events and vim.pesc(events) .. '%s*' or '')
    .. (pat and vim.pesc(pat) .. '%s*' or '') .. '(.*)$') or ''
  -- shortcut: a bare `autocmd!` outside an augroup would clear the ungrouped autocmds
  -- only; zigvim cannot select those, so it clears nothing rather than everything.
  if bang and not group and not events then
    return
  end
  if bang then
    local opts = { group = group }
    if events and events ~= '*' then
      opts.event = vim.split(events, ',')
    end
    if pat then
      opts.pattern = pat
    end
    pcall(vim.api.nvim_clear_autocmds, opts)
  end
  if not bang and cmd == '' then
    -- listing, in Neovim's format: header, "group  Event", "    pattern   command"
    local filter = { group = group }
    if events and events ~= '*' then
      filter.event = vim.split(events, ',')
    end
    if pat then
      filter.pattern = pat
    end
    local ok, list = pcall(vim.api.nvim_get_autocmds, filter)
    local lines, last = { '--- Autocommands ---' }, nil
    for _, a in ipairs(ok and list or {}) do
      local head = (a.group_name and a.group_name .. '  ' or '') .. a.event
      if head ~= last then
        lines[#lines + 1] = head
        last = head
      end
      local what = a.command ~= '' and a.command or (a.desc or '<Lua function>')
      lines[#lines + 1] = string.format('    %-9s %s', a.pattern or '*', what)
    end
    vim._out(table.concat(lines, '\n') .. '\n')
    return
  end
  if not events or not pat or cmd == '' then
    return
  end
  local once, nested = false, false
  while true do
    local flag, more = cmd:match('^%+%+(%a+)%s*(.*)$')
    if flag == 'once' then
      once, cmd = true, more
    elseif flag == 'nested' then
      nested, cmd = true, more
    else
      break
    end
  end
  vim.api.nvim_create_autocmd(vim.split(events, ','), {
    group = group, pattern = vim.split(pat, ','), command = cmd, once = once, nested = nested,
  })
end

-- indent({lnum}): -1 for a non-number or out-of-range line (what Neovim returns from Lua).
function vim.fn.indent(lnum)
  lnum = tonumber(lnum)
  if not lnum or lnum < 1 or lnum > vim.api.nvim_buf_line_count(0) then
    return -1
  end
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  local ts, col = vim.bo.tabstop, 0
  for ch in line:match('^[ \t]*'):gmatch('.') do
    col = ch == '\t' and (math.floor(col / ts) + 1) * ts or col + 1
  end
  return col
end

-- shortcut: one non-floating window per tab; real floats come with window support.
vim.api.nvim_win_get_config = function(win)
  if not vim.api.nvim_win_is_valid(win) then
    error('Invalid window id: ' .. tostring(win), 0)
  end
  return {
    external = false, focusable = true, hide = false, mouse = true, relative = '', split = 'left',
    style = '', height = vim.api.nvim_win_get_height(win), width = vim.api.nvim_win_get_width(win),
  }
end

-- getbufinfo([{buf}] | [{dict}]): shortcut: lastused is always 0.
function vim.fn.getbufinfo(arg)
  local bufs = vim.api.nvim_list_bufs()
  if type(arg) == 'number' or type(arg) == 'string' then
    local b = vim.fn.bufnr(arg)
    bufs = (b > 0 and vim.api.nvim_buf_is_valid(b)) and { b } or {}
  end
  local filt = type(arg) == 'table' and arg or {}
  local cur = vim.api.nvim_get_current_buf()
  local out = {}
  for _, b in ipairs(bufs) do
    local wins = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_buf(w) == b
    end, vim.api.nvim_list_wins())
    local info = {
      bufnr = b,
      changed = vim.bo[b].modified and 1 or 0,
      changedtick = vim.b[b].changedtick or 0,
      command = 0,
      hidden = (#wins == 0 and vim.api.nvim_buf_is_loaded(b)) and 1 or 0,
      lastused = 0,
      linecount = vim.api.nvim_buf_line_count(b),
      listed = vim.bo[b].buflisted and 1 or 0,
      lnum = b == cur and vim.api.nvim_win_get_cursor(0)[1] or 1,
      loaded = vim.api.nvim_buf_is_loaded(b) and 1 or 0,
      name = vim.api.nvim_buf_get_name(b),
      variables = vim.b[b],
      windows = wins,
    }
    if not ((filt.buflisted == 1 and info.listed == 0) or (filt.bufloaded == 1 and info.loaded == 0)
      or (filt.bufmodified == 1 and info.changed == 0)) then
      out[#out + 1] = info
    end
  end
  return out
end

-- SHA-256 (FIPS 180-4) over LuaJIT's bit library.
do
  local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
  local rrot, rshift, tobit = bit.ror, bit.rshift, bit.tobit
  local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  }
  function vim.fn.sha256(msg)
    msg = tostring(msg)
    local len = #msg
    msg = msg .. '\128' .. string.rep('\0', (55 - len) % 64)
    local bits = len * 8
    for i = 7, 0, -1 do
      msg = msg .. string.char(math.floor(bits / 2 ^ (8 * i)) % 256)
    end
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local w = {}
    for chunk = 1, #msg, 64 do
      for i = 0, 15 do
        local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
        w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
      end
      for i = 16, 63 do
        local s0 = bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3))
        local s1 = bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10))
        w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
      end
      local a, b, c, d, e, f, g, hh = unpack(h)
      for i = 0, 63 do
        local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = tobit(hh + S1 + ch + K[i + 1] + w[i])
        local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        hh, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + S0 + maj)
      end
      for i, v in ipairs({ a, b, c, d, e, f, g, hh }) do
        h[i] = tobit(h[i] + v)
      end
    end
    local out = {}
    for i = 1, 8 do
      out[i] = bit.tohex(h[i], 8)
    end
    return table.concat(out)
  end
end

-- findfile({name} [, {path} [, {count}]]): first match in 'path'-style dirs; "dir;" searches
-- upward from dir. shortcut: no "**" globs, stop dirs after ";", or count/list results.
function vim.fn.findfile(name, path, _count)
  name = tostring(name)
  local function hit(p)
    local st = vim.uv.fs_stat(p)
    return st and st.type ~= 'directory'
  end
  if name:sub(1, 1) == '/' then
    return hit(name) and name or ''
  end
  local cwd = vim.fn.getcwd()
  local bufdir = vim.fn.expand('%:p:h')
  local dirs = (path == nil or path == '') and (vim.o.path or '.,,') or path
  for _, entry in ipairs(vim.split(dirs, ',', { plain = true })) do
    local upward = entry:sub(-1) == ';'
    local dir = upward and entry:sub(1, -2) or entry
    if dir == '.' then
      dir = bufdir ~= '' and bufdir or cwd
    elseif dir == '' then
      dir = cwd
    elseif dir:sub(1, 1) ~= '/' then
      dir = vim.fs.normalize(cwd .. '/' .. dir)
    end
    while dir do
      local p = (dir == '/' and '' or dir) .. '/' .. name
      if hit(p) then
        return p
      end
      local parent = upward and vim.fs.dirname(dir) or nil
      dir = parent ~= dir and parent or nil
    end
  end
  return ''
end

-- Native helpers behind vim.str_utfindex / vim.str_byteindex (C in Neovim).
-- _str_utfindex(s [, index]): UTF-32 and UTF-16 counts of the characters that start
-- within the first {index} bytes. _str_byteindex(s, index, use_utf16): byte length
-- of the first {index} code units (ending a character it splits); nil past the end.
local function utf_chars(s)
  local out = {}
  for start, ch in s:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
    out[#out + 1] = { start = start, len = #ch, wide = #ch == 4 }
  end
  return out
end
function vim._str_utfindex(s, index)
  s = tostring(s)
  index = index or #s
  if index > #s then
    return nil
  end
  local n32, n16 = 0, 0
  for _, c in ipairs(utf_chars(s)) do
    if c.start > index then
      break
    end
    n32, n16 = n32 + 1, n16 + (c.wide and 2 or 1)
  end
  return n32, n16
end
function vim._str_byteindex(s, index, use_utf16)
  s = tostring(s)
  local units, bytes = 0, 0
  if index == 0 then
    return 0
  end
  for _, c in ipairs(utf_chars(s)) do
    units = units + ((use_utf16 and c.wide) and 2 or 1)
    bytes = c.start + c.len - 1
    if units >= index then
      return bytes
    end
  end
  return nil
end

-- vim.str_byteindex / vim.str_utfindex: copied from Neovim's runtime editor.lua.
local utfs = { ['utf-8'] = true, ['utf-16'] = true, ['utf-32'] = true }
function vim.str_byteindex(s, encoding, index, strict_indexing)
  if type(encoding) == 'number' then
    -- Legacy support for old API
    -- Parameters: ~
    --   • {str}        (`string`)
    --   • {index}      (`integer`)
    --   • {use_utf16}  (`boolean?`)
    vim.deprecate(
      'vim.str_byteindex',
      'vim.str_byteindex(s, encoding, index, strict_indexing)',
      '1.0'
    )
    local old_index = encoding
    local use_utf16 = index or false
    return vim._str_byteindex(s, old_index, use_utf16) or error('index out of range')
  end

  -- Avoid vim.validate for performance.
  if type(s) ~= 'string' or type(index) ~= 'number' then
    vim.validate('s', s, 'string')
    vim.validate('index', index, 'number')
  end

  local len = #s

  if index == 0 or len == 0 then
    return 0
  end

  if not utfs[encoding] then
    vim.validate('encoding', encoding, function(v)
      return utfs[v], 'invalid encoding'
    end)
  end

  if strict_indexing ~= nil and type(strict_indexing) ~= 'boolean' then
    vim.validate('strict_indexing', strict_indexing, 'boolean', true)
  end
  if strict_indexing == nil then
    strict_indexing = true
  end

  if encoding == 'utf-8' then
    if index > len then
      return strict_indexing and error('index out of range') or len
    end
    return index
  end
  return vim._str_byteindex(s, index, encoding == 'utf-16')
    or strict_indexing and error('index out of range')
    or len
end

function vim.str_utfindex(s, encoding, index, strict_indexing)
  if encoding == nil or type(encoding) == 'number' then
    -- Legacy support for old API
    -- Parameters: ~
    --   • {str}    (`string`)
    --   • {index}  (`integer?`)
    vim.deprecate(
      'vim.str_utfindex',
      'vim.str_utfindex(s, encoding, index, strict_indexing)',
      '1.0'
    )
    local old_index = encoding
    local col32, col16 = vim._str_utfindex(s, old_index) --[[@as integer,integer]]
    if not col32 or not col16 then
      error('index out of range')
    end
    -- Return (multiple): ~
    --     (`integer`) UTF-32 index
    --     (`integer`) UTF-16 index
    return col32, col16
  end

  if type(s) ~= 'string' or (index ~= nil and type(index) ~= 'number') then
    vim.validate('s', s, 'string')
    vim.validate('index', index, 'number', true)
  end

  if not index then
    index = math.huge
    strict_indexing = false
  end

  if index == 0 then
    return 0
  end

  if not utfs[encoding] then
    vim.validate('encoding', encoding, function(v)
      return utfs[v], 'invalid encoding'
    end)
  end

  if strict_indexing ~= nil and type(strict_indexing) ~= 'boolean' then
    vim.validate('strict_indexing', strict_indexing, 'boolean', true)
  end
  if strict_indexing == nil then
    strict_indexing = true
  end

  if encoding == 'utf-8' then
    local len = #s
    return index <= len and index or (strict_indexing and error('index out of range') or len)
  end
  local col32, col16 = vim._str_utfindex(s, index) --[[@as integer?,integer?]]
  local col = encoding == 'utf-16' and col16 or col32
  if col then
    return col
  end
  if strict_indexing then
    error('index out of range')
  end
  local max32, max16 = vim._str_utfindex(s)--[[@as integer integer]]
  return encoding == 'utf-16' and max16 or max32
end

function vim.fn.environ()
  return vim.uv.os_environ()
end

-- Sign definitions. shortcut: definitions only; sign_place and drawing signs in the TUI are not done.
do
  local signs, order = {}, {}
  local function define(name, dict)
    local def = { name = name }
    for k, v in pairs(dict or {}) do
      def[k] = v
    end
    if def.text and vim.fn.strdisplaywidth(def.text) > 2 then
      error('Vim:E239: Invalid sign text: ' .. def.text, 0)
    end
    if not signs[name] then
      order[#order + 1] = name
    end
    signs[name] = def
    return 0
  end
  function vim.fn.sign_define(name, dict)
    if type(name) == 'table' then
      local res = {}
      for i, d in ipairs(name) do
        res[i] = define(d.name, d)
      end
      return res
    end
    return define(name, dict)
  end
  function vim.fn.sign_getdefined(name)
    local res = {}
    for _, n in ipairs(order) do
      if signs[n] and (name == nil or name == n) then
        res[#res + 1] = vim.deepcopy(signs[n])
      end
    end
    return res
  end
  function vim.fn.sign_undefine(name)
    if name == nil then
      signs, order = {}, {}
    else
      signs[name] = nil
    end
    return 0
  end
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

  -- Source runtime plugins (plugin/*.lua files from runtime path). netrw, tutor and the
  -- archive plugins are runtime/plugin/*.lua files too, so a config (or lazy.nvim, which
  -- sources plugins itself and then turns 'loadplugins' off) can skip them by name.
  local rtp = vim.go.loadplugins and vim.o.runtimepath
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
  vim_did_enter = 0,
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
  exiting = vim.NIL, -- lazy.nvim skips VeryLazy unless this is vim.NIL
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
    if type(k) == 'number' then -- vim.w[id].name
      return var_table('w', k == 0 and vim.api.nvim_get_current_win() or k)
    end
    return var_table('w', vim.api.nvim_get_current_win())[k]
  end,
  __newindex = function(_, k, v)
    var_table('w', vim.api.nvim_get_current_win())[k] = v
  end,
})
vim.t = setmetatable({}, {
  __index = function(_, k)
    if type(k) == 'number' then -- vim.t[id].name
      return var_table('t', k == 0 and vim.api.nvim_get_current_tabpage() or k)
    end
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

-- shortcut: zigvim has one tabpage holding every window; real multiple tabs (and
-- nvim_open_tabpage) come with tab support.
local function check_tab(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) then
    api_error('Invalid tabpage id: ' .. tostring(tab))
  end
end
local function check_win(win)
  if not vim.api.nvim_win_is_valid(win) then
    api_error('Invalid window id: ' .. tostring(win))
  end
end
vim.api.nvim_tabpage_list_wins = function(tab)
  check_tab(tab)
  return vim.api.nvim_list_wins()
end
vim.api.nvim_win_get_tabpage = function(win)
  check_win(win)
  return vim.api.nvim_get_current_tabpage()
end
vim.api.nvim_tabpage_set_win = function(tab, win)
  check_tab(tab)
  check_win(win)
  vim.api.nvim_set_current_win(win)
end
vim.api.nvim_set_current_tabpage = function(tab)
  check_tab(tab)
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
-- Option metadata generated from the oracle (scripts/gen_options_info.lua).
-- shortcut: was_set only knows options set through zigvim's option store, and
-- last_set_sid/linenr/chan are always 0 (no script tracking).
local function option_info(name, meta)
  local default = meta.default
  if default == nil then
    default = option_defaults[name]
  end
  return {
    name = name, shortname = meta.shortname, type = meta.type, scope = meta.scope,
    global_local = meta.global_local, commalist = meta.commalist, flaglist = meta.flaglist,
    allows_duplicates = meta.allows_duplicates, default = default,
    was_set = rawget(option_store, name) ~= nil, last_set_sid = 0, last_set_linenr = 0, last_set_chan = 0,
  }
end

vim.api.nvim_get_all_options_info = function()
  local info = {}
  for name, meta in pairs(require('vim._options_info')) do
    info[name] = option_info(name, meta)
  end
  return info
end

vim.api.nvim_get_option_info2 = function(name, _opts)
  local all = require('vim._options_info')
  local long = all[name] and name
  if not long then
    for n, meta in pairs(all) do
      if meta.shortname == name then
        long = n
        break
      end
    end
  end
  if not long then
    api_error("Unknown option '" .. tostring(name) .. "'")
  end
  return option_info(long, all[long])
end

function vim.fn.bufloaded(buf)
  local b = vim.fn.bufnr(buf)
  return (b > 0 and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b)) and 1 or 0
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
    noremap = opts.noremap == true and 1 or 0,
    silent = opts.silent and 1 or 0,
    expr = opts.expr and 1 or 0,
    nowait = opts.nowait and 1 or 0,
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

-- shortcut: mode '' looks in 'n' only, abbreviations (abbr) are not supported.
function vim.fn.maparg(name, mode, abbr, dict)
  mode = (mode == nil or mode == '') and 'n' or mode
  local want = normalize_lhs(tostring(name))
  local found
  for _, list in ipairs({ vim.api.nvim_buf_get_keymap(0, mode), vim.api.nvim_get_keymap(mode) }) do
    for _, m in ipairs(list) do
      if m.lhs == want then
        found = m
        break
      end
    end
    if found then
      break
    end
  end
  if dict and dict ~= 0 then
    if not found then
      return {}
    end
    local d = vim.deepcopy(found)
    d.abbr, d.lhsraw, d.scriptversion = 0, found.lhs, 1
    return d
  end
  if not found then
    return ''
  end
  return found.callback and '<Lua callback>' or found.rhs
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
    opts = vim.deepcopy(opts or {})
    opts.noremap = not opts.remap
    opts.remap = nil
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

  -- b:changedtick: Neovim starts the first buffer at 2 and new ones at 1; every
  -- change adds 1. Kept in the buffer's variables so vim.b and nvim_buf_get_var see it.
  local function bump_tick(id)
    local vars = buffer_var_table(id)
    vars.changedtick = (vars.changedtick or (id == 1 and 2 or 1)) + 1
  end
  vim.api.nvim_buf_get_changedtick = function(buf)
    local id = check_buf(buf)
    local vars = buffer_var_table(id)
    vars.changedtick = vars.changedtick or (id == 1 and 2 or 1)
    return vars.changedtick
  end

  local raw_set_lines = vim.api.nvim_buf_set_lines
  local set_text_active = false -- nvim_buf_set_text reports its own, column-exact on_bytes
  vim.api.nvim_buf_set_lines = function(buf, start, end_, strict, lines)
    local id = check_buf(buf)
    -- on_lines gets resolved 0-based lines like Neovim (-1 means past the last line)
    local n = vim.api.nvim_buf_line_count(id)
    if start < 0 then
      start = n + start + 1
    end
    if end_ < 0 then
      end_ = n + end_ + 1
    end
    start, end_ = math.min(start, n), math.min(end_, n)
    -- on_lines' byte_count: size of the replaced lines, newlines included
    local byte_count = 0
    local want_bytes = not set_text_active and has_on_bytes(id)
    local start_byte = want_bytes and byte_offset(id, start) or 0
    if buffer_attach_callbacks[id] and end_ > start then
      for _, l in ipairs(vim.api.nvim_buf_get_lines(id, start, end_, false)) do
        byte_count = byte_count + #l + 1
      end
    end
    local result = raw_set_lines(id, start, end_, strict, lines)
    bump_tick(id)
    local count = 0
    if type(lines) == 'table' then
      for _ in pairs(lines) do
        count = count + 1
      end
    end
    fire_buf_attach(id, start, end_, start + count, byte_count)
    if want_bytes then
      local new_bytes = 0
      for _, l in ipairs(lines or {}) do
        new_bytes = new_bytes + #l + 1
      end
      fire_buf_bytes(id, start, 0, start_byte, end_ - start, 0, byte_count, count, 0, new_bytes)
    end
    return result
  end

  -- nvim_buf_set_text: replace a (0-based, end-exclusive col) range with {replacement} lines.
  vim.api.nvim_buf_get_text = function(buf, start_row, start_col, end_row, end_col, opts)
    local id = check_buf(buf)
    local n = vim.api.nvim_buf_line_count(id)
    if start_row < 0 then start_row = n + start_row end
    if end_row < 0 then end_row = n + end_row end
    if start_row < 0 or start_row >= n or end_row < 0 or end_row >= n then
      api_error('Index out of bounds')
    end
    if start_row > end_row then
      api_error("'start' is higher than 'end'")
    end
    local lines = vim.api.nvim_buf_get_lines(id, start_row, end_row + 1, true)
    -- negative columns count from past the end of the line (-1 is the end)
    local function col(c, line)
      if c < 0 then c = #line + 1 + c end
      return math.max(0, math.min(c, #line))
    end
    local sc, ec = col(start_col, lines[1]), col(end_col, lines[#lines])
    if #lines == 1 then
      if sc > ec then
        api_error("'start' is higher than 'end'")
      end
      return { lines[1]:sub(sc + 1, ec) }
    end
    lines[1] = lines[1]:sub(sc + 1)
    lines[#lines] = lines[#lines]:sub(1, ec)
    return lines
  end

  vim.api.nvim_buf_set_text = function(buf, start_row, start_col, end_row, end_col, replacement)
    local id = check_buf(buf)
    local n = vim.api.nvim_buf_line_count(id)
    if start_row < 0 then start_row = n + start_row end
    if end_row < 0 then end_row = n + end_row end
    if start_row > end_row or (start_row == end_row and start_col > end_col) then
      api_error("'start' is higher than 'end'")
    end
    if end_row >= n then
      api_error("Invalid 'end_row': out of range")
    end
    local old = vim.api.nvim_buf_get_lines(id, start_row, end_row + 1, true)
    local first, last = old[1], old[#old]
    if start_col > #first or end_col > #last then
      api_error("Invalid 'start_col' or 'end_col': out of range")
    end
    local new = {}
    for i, l in ipairs(replacement) do
      new[i] = l
    end
    if #new == 0 then
      new[1] = ''
    end
    local want_bytes = has_on_bytes(id)
    local start_byte, old_bytes, new_bytes = 0, 0, 0
    if want_bytes then
      start_byte = byte_offset(id, start_row) + start_col
      local removed = vim.api.nvim_buf_get_text(id, start_row, start_col, end_row, end_col, {})
      old_bytes = #table.concat(removed, '\n')
      new_bytes = #table.concat(new, '\n')
    end
    local nrep = #new
    local last_rep = #new[nrep]
    new[1] = first:sub(1, start_col) .. new[1]
    new[#new] = new[#new] .. last:sub(end_col + 1)
    set_text_active = true
    local ok, err = pcall(vim.api.nvim_buf_set_lines, id, start_row, end_row + 1, true, new)
    set_text_active = false
    if not ok then
      error(err, 0)
    end
    if want_bytes then
      local old_col = end_row == start_row and end_col - start_col or end_col
      fire_buf_bytes(id, start_row, start_col, start_byte, end_row - start_row, old_col, old_bytes, nrep - 1, last_rep, new_bytes)
    end
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

  -- Event names are case-insensitive and Vim's aliases map to one canonical event.
  local canonical_event = {}
  for name in pairs(known_events) do
    canonical_event[name:lower()] = name
  end
  for alias, name in pairs({ bufcreate = 'BufAdd', bufread = 'BufReadPost', bufwrite = 'BufWritePre', fileencoding = 'EncodingChanged' }) do
    canonical_event[alias] = name
  end

  local function validate_events(events)
    local list = {}
    for i, event in ipairs(as_list(events)) do
      list[i] = canonical_event[tostring(event):lower()]
      if not list[i] then
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
    if type(opts.group) == 'string' then -- records hold group ids
      local id = state.groups[opts.group]
      if not id then
        api_error("Invalid 'group': '" .. opts.group .. "'")
      end
      opts = vim.tbl_extend('force', opts, { group = id })
    end
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

  -- Stub for internal Neovim API function used by gitsigns and other plugins.
  -- Sets metadata for a namespace (e.g., { wins = {} }). Currently a no-op.
  vim.api.nvim__ns_set = function(ns, opts)
    -- No-op: zigvim does not currently track namespace metadata
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
  local hl_names = {}

  vim.api.nvim_get_hl_id_by_name = function(name)
    local id = hl_ids[name]
    if not id then
      id = next_hl_id
      next_hl_id = next_hl_id + 1
      hl_ids[name] = id
      hl_names[id] = name
    end
    return id
  end

  -- For the TUI: the group drawn for a name or id. Like Neovim, an undefined "@a.b.c"
  -- falls back to "@a.b", then "@a"; links are followed. nil when nothing is defined.
  function vim._hl_resolve(name)
    if type(name) == 'number' then
      name = hl_names[name]
    end
    while name do
      local group = highlight_groups[name]
      if group and next(group) ~= nil then
        local seen = 0
        while group.link and seen < 100 do
          group, seen = highlight_groups[group.link] or {}, seen + 1
        end
        return group
      end
      name = name:match('^(.+)%.[^.]+$')
    end
  end

  vim.api.nvim_set_hl = function(ns, name, val)
    val = val or {}
    local existing = highlight_groups[name]
    -- default=true never overrides a defined group; update=true merges, otherwise replace.
    if val.default and existing and next(existing) ~= nil then
      return 0
    end
    local group = (val.update and existing) and vim.deepcopy(existing) or {}
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
      for _, key in ipairs({ 'ctermfg', 'ctermbg', 'blend' }) do
        if val[key] ~= nil then
          group[key] = val[key]
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
      else
        -- Auto-generate cterm from gui attributes (Neovim behavior)
        local cterm = {}
        for _, key in ipairs(attr_keys) do
          if group[key] then
            cterm[key] = group[key]
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
    -- link = false resolves the link chain to the attributes it ends at (Neovim).
    local function resolve(group)
      local seen = 0
      while group.link and seen < 100 do
        local target = highlight_groups[group.link]
        if not target then
          return {}
        end
        group, seen = target, seen + 1
      end
      return group
    end
    local function get(group)
      return copy_group(opts.link == false and resolve(group) or group)
    end
    if opts.id ~= nil and opts.name == nil then
      opts = vim.tbl_extend('force', opts, { name = hl_names[opts.id] or '' })
    end
    if opts.name ~= nil then
      local group = highlight_groups[opts.name]
      local hl = group and get(group)
      -- an API Dict: empty results are vim.empty_dict(), like Neovim
      return (hl and next(hl) ~= nil) and hl or vim.empty_dict()
    end
    local out = {}
    for name, group in pairs(highlight_groups) do
      out[name] = get(group)
    end
    return out
  end

  -- Neovim's built-in groups (generated from the oracle, see scripts/gen_default_hl.lua).
  -- shortcut: applied at startup and on :hi clear; changing 'background' later does not reload them.
  function vim._hl_reset()
    local defaults = require('vim._default_hl')[vim.o.background == 'light' and 'light' or 'dark']
    -- Like Neovim: user groups still exist after a clear; former links stay listed, empty.
    for name, group in pairs(highlight_groups) do
      vim.api.nvim_get_hl_id_by_name(name)
      highlight_groups[name] = (group.link and not defaults[name]) and {} or nil
    end
    for name, group in pairs(defaults) do
      highlight_groups[name] = vim.deepcopy(group)
    end
  end

  -- Deprecated, still used by plugins: resolved attrs with foreground/background/special.
  vim.api.nvim_get_hl_by_name = function(name, rgb)
    if vim.fn.hlexists(name) == 0 then
      error("Invalid highlight name: '" .. tostring(name) .. "'", 0)
    end
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    local src = rgb and hl or (hl.cterm or {})
    local out = {}
    for _, key in ipairs(attr_keys) do
      out[key] = src[key]
    end
    if rgb then
      out.foreground, out.background, out.special = hl.fg, hl.bg, hl.sp
    else
      out.foreground, out.background = hl.ctermfg, hl.ctermbg
    end
    return out
  end

  function vim.fn.hlexists(name)
    name = tostring(name)
    if highlight_groups[name] or hl_ids[name] then
      return 1
    end
    local lower = name:lower()
    for n in pairs(highlight_groups) do
      if n:lower() == lower then
        return 1
      end
    end
    return 0
  end

  -- :highlight clear [{group}] and :highlight [default] link {from} {to}.
  -- shortcut: attribute arguments (guifg=, gui=bold, ...) are ignored.
  function vim._hl_command(bang, rest)
    local group = rest:match('^clear%s+(%S+)$')
    if rest == 'clear' then
      vim._hl_reset()
    elseif group then
      highlight_groups[group] = nil
    else
      local default, from, to = rest:match('^(d?e?f?a?u?l?t?)%s*link%s+(%S+)%s+(%S+)$')
      if from then
        if to == 'NONE' then
          highlight_groups[from] = nil
        elseif not (default ~= '' and highlight_groups[from] and not bang) then
          vim.api.nvim_set_hl(0, from, { link = to, default = default ~= '' or nil })
        end
      end
    end
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
  -- The rest of Neovim's vim._submodules (and vim._core.editor's) that the eager list
  -- above does not load.
  local lazy_modules = {
    diagnostic = 'vim.diagnostic',
    lsp = 'vim.lsp',
    treesitter = 'vim.treesitter',
    glob = 'vim.glob',
    ui = 'vim.ui',
    snippet = 'vim.snippet',
    provider = 'vim.provider',
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
    -- Like vim._init_packages: vim.uri_* from vim.uri, inspect_pos/show_pos from vim._inspector.
    if type(k) == 'string' and k:sub(1, 4) == 'uri_' then
      local val = require('vim.uri')[k]
      if val ~= nil then
        rawset(t, k, val)
        return val
      end
    elseif k == 'inspect_pos' or k == 'show_pos' then
      require('vim._inspector')
      return rawget(t, k)
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
    if buf == 0 then
      buf = vim.api.nvim_get_current_buf()
    end
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
    -- ephemeral marks live for one redraw: the TUI collects them while providers run
    if opts.ephemeral then
      local list = vim._decor_ephemeral
      if not list then
        api_error('cannot set emphemeral mark outside of a decoration provider')
      end
      list[#list + 1] = {
        row = line, col = col, end_row = opts.end_row or line, end_col = opts.end_col or col,
        hl_group = opts.hl_group, priority = opts.priority or 4096, virt_text = opts.virt_text,
        virt_text_pos = opts.virt_text_pos,
      }
      return opts.id or 0
    end
    vim._ui_gen = vim._ui_gen + 1
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
      -- Neovim pads sign text to two cells
      sign_text = opts.sign_text and (vim.fn.strdisplaywidth(opts.sign_text) < 2 and opts.sign_text .. ' ' or opts.sign_text),
      sign_hl_group = opts.sign_hl_group,
      ns_id = ns,
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
    if ns == -1 then -- every namespace
      marks = {}
      local per_buffer = extmarks[buf == 0 and vim.api.nvim_get_current_buf() or buf] or {}
      for _, list in pairs(per_buffer) do
        for id, mark in pairs(list) do
          marks[id] = mark
        end
      end
    end
    local kinds = { sign = 'sign_text', highlight = 'hl_group', virt_text = 'virt_text', virt_lines = 'virt_lines' }
    local want = opts.type and kinds[opts.type]
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
      if end_row == -1 then
        end_row = math.huge
      end
      if end_col == -1 then -- -1 means end of line, like Neovim
        end_col = math.huge
      end
    else
      end_row, end_col = end_, math.huge
    end
    local out = {}
    for _, mark in pairs(marks) do
      local after_start = mark.row > start_row or (mark.row == start_row and (mark.col or 0) >= start_col)
      local before_end = mark.row < end_row or (mark.row == end_row and (mark.col or 0) <= end_col)
      if (not want or mark[want] ~= nil) and after_start and before_end then
        if opts.details then
          local details = { }
          for _, key in ipairs({
            'end_row', 'end_col', 'hl_group', 'hl_eol', 'priority', 'virt_text',
            'virt_text_pos', 'virt_lines', 'sign_text', 'sign_hl_group',
            'number_hl_group', 'line_hl_group', 'cursorline_hl_group', 'conceal',
            'spell', 'ui_watched', 'right_gravity', 'end_right_gravity', 'ns_id',
          }) do
            details[key] = mark[key]
          end
          details.priority = details.priority or 4096
          if details.right_gravity == nil then
            details.right_gravity = true
          end
          if details.end_col or details.end_row then
            details.end_row = details.end_row or mark.row
            details.end_right_gravity = details.end_right_gravity or false
            details.hl_eol = details.hl_eol or false
          end
          if details.virt_text then
            details.virt_text_pos = details.virt_text_pos or 'eol'
            details.virt_text_hide = mark.virt_text_hide or false
            details.virt_text_repeat_linebreak = mark.virt_text_repeat_linebreak or false
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
    vim._ui_gen = vim._ui_gen + 1
    local marks = ns_marks(buf, ns)
    if marks[id] == nil then
      return false
    end
    marks[id] = nil
    return true
  end

  vim.api.nvim_buf_clear_namespace = function(buf, ns, line_start, line_end)
    vim._ui_gen = vim._ui_gen + 1
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    line_start = line_start or 0
    if line_end == nil or line_end < 0 then -- -1: to the end of the buffer
      line_end = math.huge
    end
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

-- ------------------------------------------------- Vimscript expression eval
-- shortcut: the subset mapping <expr>s use (literals, v:/g:/b:/w:/&option vars,
-- ?:, || &&, comparisons, + - * / % . .., !, unary -, [i], fn calls). No lists,
-- dicts, lambdas or slices; add them when a plugin needs them.
do
  local function num(v)
    if type(v) == 'number' then
      return v
    elseif type(v) == 'boolean' then
      return v and 1 or 0
    end
    return tonumber(tostring(v):match('^%s*(-?%d+)')) or 0
  end

  local function str(v)
    if type(v) == 'boolean' then
      return v and 'v:true' or 'v:false'
    end
    return v == nil and '' or tostring(v)
  end

  local function eval(src)
    local pos = 1
    local function skip()
      pos = src:match('^%s*()', pos)
    end
    local function peek(pat)
      skip()
      return src:match('^' .. pat, pos)
    end
    local function take(pat)
      local m = peek(pat)
      if m then
        pos = pos + #m
      end
      return m
    end
    local function fail()
      error('E15: Invalid expression: "' .. src .. '"', 0)
    end

    local expr1
    local function primary()
      local v
      if take('%(') then
        v = expr1()
        if not take('%)') then
          fail()
        end
      elseif peek("'") then
        local s, e = src:match("^'(.-)'()", pos)
        while s and src:sub(e, e) == "'" do -- '' is a quote inside '...'
          local more, e2 = src:match("^'(.-)'()", e)
          s, e = s .. "'" .. (more or ''), e2
        end
        if not s then
          fail()
        end
        v, pos = s, e
      elseif peek('"') then
        local s, e = src:match('^"(.-[^\\]?)"()', pos)
        if not s then
          fail()
        end
        v, pos = s:gsub('\\(.)', { n = '\n', t = '\t', ['\\'] = '\\', ['"'] = '"' }), e
      elseif peek('%d') then
        v = tonumber(take('0[xX]%x+') or take('%d+'))
      elseif peek('&') then
        take('&')
        local scope = take('[lg]:') or ''
        local name = take('[%w_]+') or fail()
        v = scope == 'l:' and vim.opt_local[name]:get() or vim.o[name]
      elseif peek('[%a_]') then
        local scope = take('[vgbwtsl]:') or ''
        local name = take('[%w_#]+') or fail()
        if take('%(') then
          local args = {}
          if not take('%)') then
            repeat
              args[#args + 1] = expr1()
            until not take(',')
            if not take('%)') then
              fail()
            end
          end
          local f = vim.fn[scope .. name]
          v = f(unpack(args))
        else
          local tbl = ({ ['v:'] = vim.v, ['g:'] = vim.g, ['b:'] = vim.b, ['w:'] = vim.w, ['t:'] = vim.t })[scope]
          if not tbl then
            error('E121: Undefined variable: ' .. scope .. name, 0)
          end
          v = tbl[name]
          if v == nil then
            error('E121: Undefined variable: ' .. scope .. name, 0)
          end
        end
      else
        fail()
      end
      while take('%[') do
        local i = num(expr1())
        if not take('%]') then
          fail()
        end
        v = str(v):sub(i + 1, i + 1)
      end
      return v
    end
    local function unary()
      if take('!') then
        return num(unary()) == 0 and 1 or 0
      elseif take('%-') then
        return -num(unary())
      elseif take('%+') then
        return num(unary())
      end
      return primary()
    end
    local function mul()
      local v = unary()
      while true do
        local op = take('[%*/%%]')
        if not op then
          return v
        end
        local r = num(unary())
        v = num(v)
        v = op == '*' and v * r or (r == 0 and 0 or (op == '/' and (v / r >= 0 and math.floor(v / r) or math.ceil(v / r)) or math.fmod(v, r)))
      end
    end
    local function add()
      local v = mul()
      while true do
        local op = take('%.%.') or take('%.') or take('[%+%-]')
        if not op then
          return v
        end
        local r = mul()
        if op == '+' then
          v = num(v) + num(r)
        elseif op == '-' then
          v = num(v) - num(r)
        else
          v = str(v) .. str(r)
        end
      end
    end
    local function cmp()
      local v = add()
      local op = take('[=!]=[#?]?') or take('[<>]=?[#?]?')
      if not op then
        return v
      end
      local r = add()
      local base, ic = op:gsub('[#?]$', ''), op:sub(-1) == '?'
      local a, b
      if type(v) == 'string' and type(r) == 'string' then
        a, b = ic and v:lower() or v, ic and r:lower() or r
      else
        a, b = num(v), num(r)
      end
      local res = (base == '==' and a == b) or (base == '!=' and a ~= b) or (base == '<' and a < b)
        or (base == '>' and a > b) or (base == '<=' and a <= b) or (base == '>=' and a >= b)
      return res and 1 or 0
    end
    local function land()
      local v = cmp()
      while take('&&') do
        local r = cmp()
        v = (num(v) ~= 0 and num(r) ~= 0) and 1 or 0
      end
      return v
    end
    local function lor()
      local v = land()
      while take('||') do
        local r = land()
        v = (num(v) ~= 0 or num(r) ~= 0) and 1 or 0
      end
      return v
    end
    expr1 = function()
      local v = lor()
      if take('%?') then
        local a = expr1()
        if not take(':') then
          fail()
        end
        local b = expr1()
        return num(v) ~= 0 and a or b
      end
      return v
    end

    local v = expr1()
    skip()
    if pos <= #src then
      fail()
    end
    return v
  end

  vim.api.nvim_eval = function(expr)
    return eval(tostring(expr))
  end
  vim.fn.eval = vim.api.nvim_eval
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
    local b = vim.fn.bufnr(expr)
    return (b > 0 and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted) and 1 or 0
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

  local function reg_name(reg)
    return (reg == nil or reg == '') and '"' or tostring(reg)
  end

  -- '+' and '*' use the OS clipboard when a tool is found (subset of Neovim's provider order).
  -- shortcut: '*' is the clipboard too (no X11 primary selection); upgrade if someone needs it.
  local clip_tools = {
    { name = 'pbcopy', copy = 'pbcopy', paste = 'pbpaste' },
    { name = 'wl-copy', env = 'WAYLAND_DISPLAY', copy = 'wl-copy --type text/plain', paste = 'wl-paste --no-newline' },
    { name = 'xclip', env = 'DISPLAY', copy = 'xclip -i -selection clipboard', paste = 'xclip -o -selection clipboard' },
    { name = 'xsel', env = 'DISPLAY', copy = 'xsel -i -b', paste = 'xsel -o -b' },
    { name = 'win32yank.exe', copy = 'win32yank.exe -i --crlf', paste = 'win32yank.exe -o --lf' },
  }
  local clip -- false once looked up and none found
  local function clip_tool()
    if clip == nil then
      clip = false
      for _, t in ipairs(clip_tools) do
        if (not t.env or os.getenv(t.env)) and vim.fn.executable(t.name) == 1 then
          clip = t
          break
        end
      end
    end
    return clip
  end

  vim.fn['provider#clipboard#Executable'] = function()
    local t = clip_tool()
    return t and t.name or ''
  end

  -- Registers hold { text = lines, linewise = bool }; the TUI shares this store.
  function vim._reg_get(reg)
    reg = reg_name(reg)
    local t = (reg == '+' or reg == '*') and clip_tool()
    if t then
      local f = io.popen(t.paste, 'r')
      local text = f and f:read('*a') or ''
      if f then
        f:close()
      end
      local last = registers[reg]
      -- Our own last copy keeps its register type; anything else is typed by its trailing newline.
      if last and table.concat(last.text, '\n') .. (last.linewise and '\n' or '') == text then
        return last
      end
      local lw = text:sub(-1) == '\n'
      registers[reg] = { text = vim.split(lw and text:sub(1, -2) or text, '\n', { plain = true }), linewise = lw }
    end
    return registers[reg]
  end

  function vim._reg_set(reg, lines, linewise)
    reg = reg_name(reg)
    registers[reg] = { text = lines, linewise = linewise and true or false }
    local t = (reg == '+' or reg == '*') and clip_tool()
    local f = t and io.popen(t.copy, 'w')
    if f then
      f:write(table.concat(lines, '\n') .. (linewise and '\n' or ''))
      f:close()
    end
  end

  -- The register an unprefixed yank/put uses, following 'clipboard'.
  function vim._reg_default()
    local cb = vim.o.clipboard or ''
    if cb:find('unnamedplus', 1, true) then
      return '+'
    elseif cb:find('unnamed', 1, true) then
      return '*'
    end
    return '"'
  end

  function vim.fn.getreg(reg, _, list)
    local r = vim._reg_get(reg)
    if list and list ~= 0 then
      return r and vim.deepcopy(r.text) or {}
    end
    if not r then
      return ''
    end
    return table.concat(r.text, '\n') .. (r.linewise and '\n' or '')
  end

  function vim.fn.setreg(reg, value, opts)
    opts = type(opts) == 'string' and opts or ''
    local lines, linewise
    if type(value) == 'table' then
      lines, linewise = vim.deepcopy(value), true
    else
      value = tostring(value)
      linewise = value:sub(-1) == '\n'
      lines = vim.split(linewise and value:sub(1, -2) or value, '\n', { plain = true })
    end
    if opts:find('[lV]') then
      linewise = true
    elseif opts:find('[cvb]') then
      linewise = false
    end
    vim._reg_set(reg, lines, linewise)
    return 0
  end

  function vim.fn.getregtype(reg)
    local r = vim._reg_get(reg)
    if r == nil then
      return ''
    end
    return r.linewise and 'V' or 'v'
  end

  function vim.fn.strchars(s)
    s = tostring(s)
    local count = 0
    for _ in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      count = count + 1
    end
    return count
  end

  -- Tabs expand to the next 'tabstop' counted from screen column {col} (0-based).
  function vim.fn.strdisplaywidth(s, col)
    s = tostring(s)
    if not s:find('\t', 1, true) then
      return vim.api.nvim_strwidth(s)
    end
    local start = tonumber(col) or 0
    local cur, ts = start, vim.bo.tabstop
    for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      cur = cur + (ch == '\t' and ts - cur % ts or vim.api.nvim_strwidth(ch))
    end
    return cur - start
  end

  -- virtcol({expr} [, {list}]): last screen column of the character at {expr}
  -- ('.', '$', "'m" or {lnum, col}); with {list}, {first, last}. 0 for an invalid line.
  function vim.fn.virtcol(expr, list)
    local lnum, col
    if type(expr) == 'table' then
      lnum, col = tonumber(expr[1]), expr[2]
    elseif expr == '.' or expr == '$' then
      local c = vim.api.nvim_win_get_cursor(0)
      lnum, col = c[1], expr == '$' and '$' or c[2] + 1
    elseif type(expr) == 'string' and expr:sub(1, 1) == "'" then
      local m = vim.api.nvim_buf_get_mark(0, expr:sub(2, 2))
      lnum, col = m[1], m[2] + 1
    end
    local wrap = function(a, b)
      return (list and list ~= 0) and { a, b } or b
    end
    if not lnum or lnum < 1 or lnum > vim.api.nvim_buf_line_count(0) then
      return wrap(0, 0)
    end
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    col = tonumber(col)
    if not col or col > #line then
      local w = vim.fn.strdisplaywidth(line) + 1
      return wrap(w, w)
    end
    local start = math.max(1, col)
    while start > 1 and (line:byte(start) or 0) >= 0x80 and line:byte(start) < 0xC0 do
      start = start - 1 -- back to the first byte of a multi-byte character
    end
    local before = vim.fn.strdisplaywidth(line:sub(1, start - 1))
    local ch = line:match('^[%z\1-\127\194-\244][\128-\191]*', start) or ''
    return wrap(before + 1, math.max(before + 1, before + vim.fn.strdisplaywidth(ch, before)))
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
      clipboard = vim.fn['provider#clipboard#Executable']() ~= '',
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
    'close', 'packadd', 'lcd', 'cd', 'pwd', 'version', 'help', 'messages', 'lsp',
    'nohlsearch', 'noh', 'redraw',
  }) do
    builtin_commands[name] = true
  end

  -- shortcut: name, bang and whitespace-split args only; no ranges, counts, registers,
  -- command modifiers or per-command nargs/addr. Add them when a plugin needs them.
  function vim.api.nvim_parse_cmd(str, _opts)
    local name, bang, rest = tostring(str):match('^[%s:]*(%a[%w_]*)(!?)%s*(.-)%s*$')
    if not name or not (builtin_commands[name] or (vim._user_commands and vim._user_commands[name])) then
      error('Parsing command-line: E492: Not an editor command: ' .. tostring(str), 0)
    end
    local args = {}
    for word in rest:gmatch('%S+') do
      args[#args + 1] = word
    end
    return {
      cmd = name, bang = bang == '!', args = args, addr = 'none', nargs = '*', nextcmd = '',
      magic = { bar = false, file = false },
      mods = {
        browse = false, confirm = false, emsg_silent = false, filter = { force = false, pattern = '' },
        hide = false, horizontal = false, keepalt = false, keepjumps = false, keepmarks = false,
        keeppatterns = false, lockmarks = false, noautocmd = false, noswapfile = false, sandbox = false,
        silent = false, split = '', tab = -1, unsilent = false, verbose = -1, vertical = false,
      },
    }
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
      if builtin_commands[rest] or (vim._user_commands and vim._user_commands[rest]) then
        return 2
      end
      return 0
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
    -- os.tmpname() creates the file; Neovim only returns a fresh name.
    local name = os.tmpname()
    os.remove(name)
    return name
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
    if type(opts) == 'table' and opts.lines ~= nil then
      -- parse lines with 'errorformat' without touching the quickfix list
      return { items = require('vim._efm').parse(opts.efm or vim.o.errorformat or '', opts.lines) }
    end
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

-- Runtime plugins that Neovim ships as Vimscript are reimplemented in Lua
-- under src/lua/ and embedded in the binary. Register a package searcher for
-- them before the requires below.
do
  local embedded = _G._ZIGVIM_EMBEDDED
  if type(embedded) == 'table' then
    local searchers = package.loaders or package.searchers
    table.insert(searchers, 1, function(name)
      local source = embedded[name]
      if not source then
        return nil
      end
      local chunk, err = loadstring(source, '@' .. name)
      if not chunk then
        return '\n\t' .. tostring(err)
      end
      return chunk
    end)
    _G._ZIGVIM_EMBEDDED = nil
  end
end

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

-- rplugin.vim: the manifest and :UpdateRemotePlugins command.
local ok_remote, remote = pcall(require, 'vim._remote')
if ok_remote then
  remote.setup()
else
  io.stderr:write('Warning: failed to load vim._remote: ' .. tostring(remote) .. '\n')
end

-- Built-in highlight groups, as Neovim has before any colorscheme.
vim._hl_reset()

function vim.fn.screenrow()
  return vim._tui_screen and (select(1, vim._tui_screen())) or 1
end
function vim.fn.screencol()
  return vim._tui_screen and (select(2, vim._tui_screen())) or 1
end

-- Type markers Neovim's C core defines for API values (plugins index tables with them).
vim.type_idx, vim.val_idx = true, false
vim.types = { array = 5, float = 3, dictionary = 6, [5] = 'array', [3] = 'float', [6] = 'dictionary' }

-- vim.regex (Neovim: Vim's C regex engine).
function vim.regex(pattern)
  return require('vim._regex').new(tostring(pattern))
end

-- vim.diff (Neovim: xdiff in C); vim.text.diff calls it.
function vim.diff(a, b, opts)
  return require('vim._diff').diff(a, b, opts)
end

-- luv's async form: fs_*(..., callback) runs and calls callback(err, result) later.
-- shortcut: the work itself is still synchronous; only the callback is deferred.
for name, fn in pairs(vim.uv) do
  if type(name) == 'string' and name:match('^fs_') and name ~= 'fs_scandir_next' and type(fn) == 'function' then
    vim.uv[name] = function(...)
      local n = select('#', ...)
      local cb = n > 0 and select(n, ...) or nil
      if type(cb) ~= 'function' then
        return fn(...)
      end
      local args = { ... }
      args[n] = nil
      local res = { pcall(fn, unpack(args, 1, n - 1)) }
      vim.schedule(function()
        if not res[1] then
          cb(tostring(res[2]))
        elseif res[2] == nil then
          -- luv's failure: nil, "ENAME: message: path" (the sync side may not say why)
          cb(res[3] or ('ENOENT: no such file or directory: ' .. tostring(args[1])))
        else
          cb(nil, unpack(res, 2))
        end
      end)
      return 0
    end
  end
end

-- vim.system(), as vim._init_packages loads it (built on vim.uv.spawn / new_pipe).
require('vim._core.system')
