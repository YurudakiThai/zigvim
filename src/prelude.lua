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
