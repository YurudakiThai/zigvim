-- Distro probe: dump the observable editor state after a distribution
-- (LazyVim, AstroNvim, ...) has loaded. Runs unchanged under real nvim and
-- under zigvim; scripts/distro_diff.py compares the two snapshots.
--
--   PROBE_OUT=/tmp/out.json nvim --headless -c "lua dofile('scripts/distro_probe.lua')" -c qa!
--
-- Plain Lua only: no vim.json, so zigvim does not need it to be probed.

local function safe(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then
    return value
  end
  return 'ERR: ' .. tostring(value):sub(1, 160)
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

-- Minimal deterministic JSON encoder (sorted keys).
local function esc(s)
  return (
    s:gsub('[%c"\\]', function(ch)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[ch] or string.format('\\u%04x', ch:byte())
    end)
  )
end

local function ser(v)
  local t = type(v)
  if t == 'nil' then
    return 'null'
  elseif t == 'boolean' or t == 'number' then
    return tostring(v)
  elseif t == 'string' then
    return '"' .. esc(v) .. '"'
  elseif t == 'table' then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do
        parts[i] = ser(v[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local parts = {}
    for _, k in ipairs(sorted_keys(v)) do
      parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. ser(v[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return '"<' .. t .. '>"'
end

local out = {}

out.g = {
  mapleader = vim.g.mapleader,
  maplocalleader = vim.g.maplocalleader,
  lazy_did_setup = vim.g.lazy_did_setup,
  colors_name = vim.g.colors_name,
}

local option_names = {
  'autowrite', 'background', 'clipboard', 'completeopt', 'conceallevel', 'confirm', 'cursorline',
  'expandtab', 'fillchars', 'foldlevel', 'foldmethod', 'formatoptions', 'grepprg', 'ignorecase',
  'laststatus', 'list', 'listchars', 'mouse', 'number', 'pumblend', 'pumheight', 'relativenumber',
  'scrolloff', 'shiftwidth', 'shortmess', 'showmode', 'sidescrolloff', 'signcolumn', 'smartcase',
  'smartindent', 'spelllang', 'splitbelow', 'splitright', 'tabstop', 'termguicolors', 'timeoutlen',
  'undofile', 'updatetime', 'winminwidth', 'wrap',
}
out.opts = {}
for _, name in ipairs(option_names) do
  local value = safe(function()
    return vim.o[name]
  end)
  out.opts[name] = value
end

local keymaps = {}
for _, mode in ipairs({ 'n', 'i', 'v', 'x', 'o', 't', 'c' }) do
  local maps = safe(vim.api.nvim_get_keymap, mode)
  if type(maps) == 'table' then
    for _, map in ipairs(maps) do
      keymaps[#keymaps + 1] = mode .. ':' .. tostring(map.lhs)
    end
  end
end
table.sort(keymaps)
out.keymaps = keymaps

local commands = safe(vim.api.nvim_get_commands, { builtin = false })
if type(commands) == 'table' then
  out.commands = sorted_keys(commands)
else
  out.commands = commands
end

local groups = {}
local autocmds = safe(vim.api.nvim_get_autocmds, {})
if type(autocmds) == 'table' then
  for _, au in ipairs(autocmds) do
    if au.group_name then
      groups[au.group_name] = true
    end
  end
  out.augroups = sorted_keys(groups)
else
  out.augroups = autocmds
end

out.plugins = {}
if package.loaded['lazy'] then
  local plugins = safe(function()
    return require('lazy').plugins()
  end)
  if type(plugins) == 'table' then
    for _, plugin in ipairs(plugins) do
      out.plugins[plugin.name] = (plugin._ and plugin._.loaded) and true or false
    end
  else
    out.plugins = plugins
  end
end

local skip = {
  _G = true, package = true, coroutine = true, table = true, io = true, os = true, math = true,
  string = true, debug = true, bit = true, ffi = true, jit = true, utf8 = true, luv = true,
  uv = true, lpeg = true, mpack = true, vim = true,
}
local modules = {}
for name in pairs(package.loaded) do
  if type(name) == 'string' and not skip[name] and not name:match('^vim%.') and not name:match('^jit%.')
    and not name:match('^string%.') and not name:match('^table%.') then
    modules[#modules + 1] = name
  end
end
table.sort(modules)
out.modules = modules

out.rtp_count = #safe(vim.api.nvim_list_runtime_paths)
out.cwd_is_dir = vim.fn.isdirectory(vim.fn.getcwd()) == 1


-- Highlight groups (sample important ones used by catppuccin and UI)
local hl_groups = {
  'Normal', 'NormalFloat', 'Comment', 'Constant', 'String', 'Identifier',
  'Function', 'Statement', 'PreProc', 'Type', 'Special', 'Visual', 'Search',
  'IncSearch', 'StatusLine', 'StatusLineNC', 'TabLine', 'TabLineFill',
  'Pmenu', 'PmenuSel', 'CursorLine', 'CursorColumn', 'LineNr', 'CursorLineNr',
  'NonText', 'EndOfBuffer', 'SignColumn', 'ColorColumn',
}
out.highlights = {}
for _, name in ipairs(hl_groups) do
  local hl = safe(vim.api.nvim_get_hl, 0, { name = name })
  if type(hl) == 'table' then
    out.highlights[name] = hl
  end
end

local path = os.getenv('PROBE_OUT')
if path and path ~= '' then
  local f = assert(io.open(path, 'w'))
  f:write(ser(out))
  f:close()
else
  io.stdout:write(ser(out), '\n')
end
