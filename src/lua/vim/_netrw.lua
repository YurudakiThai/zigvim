-- Lua implementation of Neovim's netrw plugin (runtime/pack/dist/opt/netrw).
--
-- netrw is Vimscript and zigvim has no Vimscript engine, so the file browser
-- and the :N* remote-file commands are provided here with the same commands
-- and FileExplorer/Network augroups. Directory listings work in the current
-- window; zigvim has no window splits yet, so the H/V/T/L variants open the
-- same listing in place (see docs/DISTRO-LOOP.md section 6).

local api = vim.api

local M = {}

local function is_dir(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == 'directory'
end

local function abs(path)
  local full = vim.fn.fnamemodify(path == '' and '.' or path, ':p')
  if #full > 1 then
    full = full:gsub('/+$', '')
  end
  return full
end

local function dir_entries(dir)
  local entries = {}
  for _, name in ipairs(vim.uv._scandir_list(dir) or {}) do
    if name:sub(1, 1) ~= '.' then
      entries[#entries + 1] = { name = name, is_dir = is_dir(dir .. '/' .. name) }
    end
  end
  table.sort(entries, function(a, b)
    if a.is_dir ~= b.is_dir then
      return a.is_dir
    end
    return a.name < b.name
  end)
  return entries
end

local function tree_entries(dir, depth, prefix, out)
  if depth > 5 then
    return
  end
  for _, entry in ipairs(dir_entries(dir)) do
    out[#out + 1] = { name = prefix .. entry.name, is_dir = entry.is_dir, path = dir .. '/' .. entry.name }
    if entry.is_dir then
      tree_entries(dir .. '/' .. entry.name, depth + 1, prefix .. '  ', out)
    end
  end
end

local current_buf = function()
  return api.nvim_get_current_buf()
end

local function open_entry()
  local row = api.nvim_win_get_cursor(0)[1]
  local entries = vim.b.netrw_entries or {}
  local entry = entries[row]
  if not entry then
    return
  end
  local dir = vim.b.netrw_dir or abs('.')
  local target
  if entry.name == '..' then
    target = dir:match('^(.*)/[^/]*$') or '/'
  else
    target = dir .. '/' .. entry.name
  end
  if is_dir(target) then
    M.list(target)
  else
    vim.cmd.edit({ args = { target } })
  end
end

local function go_up()
  local dir = vim.b.netrw_dir or abs('.')
  M.list(dir:match('^(.*)/[^/]*$') or '/')
end

local function map(buf, lhs, fn, desc)
  api.nvim_buf_set_keymap(buf, 'n', lhs, '', {
    callback = fn,
    silent = true,
    nowait = true,
    desc = desc,
  })
end

--- Show a directory listing in the current window.
function M.list(dir)
  dir = abs(dir ~= '' and dir or '.')
  if not is_dir(dir) then
    vim.notify(('netrw: not a directory: %s'):format(dir), vim.log.levels.ERROR)
    return
  end
  local buf = current_buf()
  local lines = {
    '" Netrw Directory Listing (zigvim)',
    '"   ' .. dir .. '/',
    '"',
  }
  local by_line = {}
  local entries
  if tonumber(vim.g.netrw_liststyle) == 3 then
    entries = {}
    tree_entries(dir, 1, '', entries)
  else
    entries = { { name = '..', is_dir = true } }
    for _, entry in ipairs(dir_entries(dir)) do
      entries[#entries + 1] = entry
    end
  end
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = entry.is_dir and (entry.name .. '/') or entry.name
    by_line[#lines] = entry
  end

  vim.bo.modifiable = true
  api.nvim_buf_set_name(buf, dir)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim._buf_set_modified(buf, false)
  vim.b.netrw_dir = dir
  vim.b.netrw_entries = by_line
  api.nvim_set_current_buf(buf)
  api.nvim_win_set_cursor(0, { 1, 0 })
  api.nvim_exec_autocmds('FileType', { pattern = 'netrw', buffer = buf })

  map(buf, '<CR>', open_entry, 'netrw: open entry')
  map(buf, '-', go_up, 'netrw: go up')
  map(buf, 'q', function()
    vim.cmd.bdelete({ bang = true })
  end, 'netrw: close listing')
  map(buf, 'R', function()
    M.list(vim.b.netrw_dir or abs('.'))
  end, 'netrw: refresh listing')
  return true
end

-- ------------------------------------------------------------- remote files

local function user_args()
  local args = {}
  if vim.g.netrw_user and vim.g.netrw_user ~= '' then
    local user = vim.g.netrw_user
    if vim.g.netrw_passwd and vim.g.netrw_passwd ~= '' then
      user = user .. ':' .. vim.g.netrw_passwd
    end
    args = { '--user', user }
  end
  return args
end

local function curl_read(url)
  local cmd = { 'curl', '-fsSL' }
  for _, arg in ipairs(user_args()) do
    cmd[#cmd + 1] = arg
  end
  cmd[#cmd + 1] = url
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error(('netrw: could not read %s'):format(url), 0)
  end
  return output
end

local function split_lines(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = line
  end
  while #lines > 1 and lines[#lines] == '' do
    lines[#lines] = nil
  end
  return lines
end

local function replace_buffer(text)
  local lines = split_lines(text)
  if #lines == 0 then
    lines = { '' }
  end
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim._buf_set_modified(0, false)
end

--- Read a remote URL into the current buffer (:Nread and BufReadCmd).
function M.read(url)
  replace_buffer(curl_read(url))
end

--- Write the current buffer to a remote URL (:Nwrite and BufWriteCmd).
function M.write(url)
  local tmp = vim.fn.tempname()
  vim.fn.writefile(api.nvim_buf_get_lines(0, 0, -1, false), tmp)
  local cmd = { 'curl', '-fsS', '-T', tmp }
  for _, arg in ipairs(user_args()) do
    cmd[#cmd + 1] = arg
  end
  cmd[#cmd + 1] = url
  vim.fn.system(cmd)
  os.remove(tmp)
  if vim.v.shell_error ~= 0 then
    error(('netrw: could not write %s'):format(url), 0)
  end
  vim._buf_set_modified(0, false)
end

function M.source(url)
  local tmp = vim.fn.tempname() .. (url:match('%.lua$') and '.lua' or '.vim')
  local f = assert(io.open(tmp, 'w'))
  f:write(curl_read(url))
  f:close()
  local ok, err = pcall(vim.cmd.source, tmp)
  os.remove(tmp)
  if not ok then
    error(err, 0)
  end
end

function M.net_user_pass(...)
  local args = { ... }
  vim.g.netrw_user = args[1] or ''
  vim.g.netrw_passwd = args[2] or ''
end

function M.set_tree(enable, dir)
  vim.g.netrw_liststyle = enable and 3 or 0
  M.list(dir ~= '' and dir or (vim.b.netrw_dir or '.'))
end

-- ------------------------------------------------------------------- setup

local function create_commands()
  api.nvim_create_user_command('Explore', function(cmd)
    M.list(cmd.args ~= '' and cmd.args or vim.fn.getcwd())
  end, { nargs = '*', bang = true, complete = 'dir', desc = 'Open netrw directory listing' })

  for _, variant in ipairs({ 'Sexplore', 'Vexplore', 'Hexplore', 'Texplore', 'Lexplore', 'Pexplore', 'Nexplore' }) do
    api.nvim_create_user_command(variant, function(cmd)
      M.list(cmd.args ~= '' and cmd.args or vim.fn.getcwd())
    end, { nargs = '*', bang = true, complete = 'dir', desc = 'Open netrw directory listing' })
  end

  api.nvim_create_user_command('Nread', function(cmd)
    M.read(cmd.args)
  end, { nargs = '+', count = 1, desc = 'Read a remote file into the buffer' })

  api.nvim_create_user_command('Nwrite', function(cmd)
    M.write(cmd.args)
  end, { nargs = '+', range = true, desc = 'Write the buffer to a remote file' })

  api.nvim_create_user_command('Nsource', function(cmd)
    M.source(cmd.args)
  end, { nargs = '+', desc = 'Source a remote file' })

  api.nvim_create_user_command('Ntree', function(cmd)
    M.set_tree(true, cmd.args)
  end, { nargs = '?', complete = 'dir', desc = 'Use netrw tree listing style' })

  api.nvim_create_user_command('NetUserPass', function(cmd)
    M.net_user_pass(cmd.fargs[1], cmd.fargs[2])
  end, { nargs = '*', desc = 'Set the user name and password for network access' })
end

local function create_augroups()
  local explorer = api.nvim_create_augroup('FileExplorer', { clear = true })
  api.nvim_create_autocmd('BufEnter', {
    group = explorer,
    pattern = '*',
    callback = function(ev)
      local name = api.nvim_buf_get_name(ev.buf)
      if name ~= '' and is_dir(name) and vim.bo[ev.buf].buftype == '' and not vim.b[ev.buf].netrw_dir then
        api.nvim_buf_call(ev.buf, function()
          M.list(name)
        end)
      end
    end,
    desc = 'Browse directories with netrw',
  })
  api.nvim_create_autocmd('BufLeave', {
    group = explorer,
    pattern = '*',
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= 'netrw' then
        vim.w.netrw_prvfile = api.nvim_buf_get_name(ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd('VimEnter', {
    group = explorer,
    pattern = '*',
    callback = function(ev)
      local name = api.nvim_buf_get_name(ev.buf)
      if name ~= '' and is_dir(name) and not vim.b[ev.buf].netrw_dir then
        api.nvim_buf_call(ev.buf, function()
          M.list(name)
        end)
      end
    end,
  })

  local network = api.nvim_create_augroup('Network', { clear = true })
  local schemes = {
    'ftp://', 'rcp://', 'scp://', 'sftp://', 'http://', 'https://',
    'dav://', 'davs://', 'rsync://', 'file://',
  }
  local read_cmds = {}
  local write_cmds = {}
  for _, scheme in ipairs(schemes) do
    read_cmds[#read_cmds + 1] = scheme .. '*'
    write_cmds[#write_cmds + 1] = scheme .. '*'
  end
  api.nvim_create_autocmd('BufReadCmd', {
    group = network,
    pattern = read_cmds,
    callback = function(ev)
      if ev.match:match('^file://') then
        local path = ev.match:gsub('^file://', '')
        local lines = vim.fn.readfile(path)
        api.nvim_buf_set_lines(ev.buf, 0, -1, false, #lines > 0 and lines or { '' })
        vim._buf_set_modified(ev.buf, false)
      else
        M.read(ev.match)
      end
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = network,
    pattern = write_cmds,
    callback = function(ev)
      M.write(ev.match)
    end,
  })
end

function M.setup()
  if vim.g.loaded_netrw == 1 then
    return
  end
  vim.g.loaded_netrw = 1
  create_commands()
  create_augroups()
end

return M
