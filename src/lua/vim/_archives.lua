-- Lua implementations of Neovim's runtime/plugin gzip.vim, tarPlugin.vim and
-- zipPlugin.vim. They create the gzip/tar/zip augroups at startup and let
-- zigvim open compressed files and archive listings without a Vimscript
-- engine. Archive member write-back is not implemented (see
-- docs/DISTRO-LOOP.md section 6).

local api = vim.api

local M = {}

local tar_extensions = {
  '.tar', '.tar.gz', '.tar.bz2', '.tar.bz3', '.tar.xz', '.tar.lzma',
  '.tar.lz4', '.tar.zst', '.tar.Z', '.tgz', '.tbz', '.txz', '.tlz4', '.tzst', '.lrp',
}

local zip_extensions = {
  '.zip', '.jar', '.war', '.ear', '.whl', '.apk', '.aar', '.epub', '.docx',
  '.xlsx', '.pptx', '.odt', '.ods', '.odp', '.kmz', '.ipa', '.vsix',
}

local compressors = {
  gz = { cmd = 'gzip', flags = '-dc' },
  Z = { cmd = 'uncompress', flags = '-c' },
  bz2 = { cmd = 'bzip2', flags = '-dc' },
  bz3 = { cmd = 'bzip3', flags = '-dc' },
  xz = { cmd = 'xz', flags = '-dc' },
  lzma = { cmd = 'lzma', flags = '-dc' },
  zst = { cmd = 'zstd', flags = '-dcq' },
  lz4 = { cmd = 'lz4', flags = '-dcq' },
  lzo = { cmd = 'lzop', flags = '-dcq' },
  br = { cmd = 'brotli', flags = '-dc' },
}

local function ends_with_any(path, list)
  for _, suffix in ipairs(list) do
    if path:sub(-#suffix) == suffix then
      return true
    end
  end
  return false
end

local function archive_kind(path)
  if ends_with_any(path, tar_extensions) then
    return 'tar'
  end
  if ends_with_any(path, zip_extensions) then
    return 'zip'
  end
  local ext = path:match('%.([%w_]+)$')
  if ext and compressors[ext] then
    return 'gzip'
  end
  return nil
end

local function split_lines(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = line
  end
  while #lines > 1 and lines[#lines] == '' do
    lines[#lines] = nil
  end
  if #lines == 0 then
    lines = { '' }
  end
  return lines
end

local function set_lines(lines)
  local buf = api.nvim_get_current_buf()
  vim.bo.modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim._buf_set_modified(buf, false)
end

local function read_compressed(path)
  local ext = path:match('%.([%w_]+)$') or 'gz'
  local compressor = compressors[ext] or compressors.gz
  local text = vim.fn.system({ compressor.cmd, compressor.flags, path })
  if vim.v.shell_error ~= 0 then
    error(('gzip: could not decompress %s'):format(path), 0)
  end
  return split_lines(text)
end

local function write_compressed(path)
  local ext = path:match('%.([%w_]+)$') or 'gz'
  local compressor = compressors[ext] or compressors.gz
  local tmp = vim.fn.tempname()
  vim.fn.writefile(api.nvim_buf_get_lines(0, 0, -1, false), tmp)
  vim.fn.system({ 'sh', '-c', compressor.cmd .. ' -c "$1" > "$2"', 'sh', tmp, path })
  os.remove(tmp)
  if vim.v.shell_error ~= 0 then
    error(('gzip: could not write %s'):format(path), 0)
  end
  vim._buf_set_modified(0, false)
end

local function archive_entries(kind, path)
  local cmd
  if kind == 'tar' then
    cmd = { 'tar', '-tf', path }
  else
    cmd = { 'unzip', '-Z1', path }
  end
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error(('%s: could not list %s'):format(kind, path), 0)
  end
  local entries = {}
  for line in output:gmatch('[^\n]+') do
    entries[#entries + 1] = line
  end
  return entries
end

local function member_contents(kind, path, member)
  local cmd
  if kind == 'tar' then
    cmd = { 'tar', '-xOf', path, member }
  else
    cmd = { 'unzip', '-p', path, member }
  end
  local text = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error(('%s: could not read %s'):format(kind, member), 0)
  end
  return text
end

local function open_member(archive, kind)
  local row = api.nvim_win_get_cursor(0)[1]
  local entries = vim.b.archive_entries or {}
  local member = entries[row]
  if not member or member:sub(-1) == '/' then
    return
  end
  local text = member_contents(kind, archive, member)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(buf)
  api.nvim_buf_set_name(buf, (kind == 'tar' and 'tarfile::' or 'zipfile::') .. archive .. '/' .. member)
  api.nvim_buf_set_lines(buf, 0, -1, false, split_lines(text))
  vim._buf_set_modified(buf, false)
  local ft = vim.filetype.match({ filename = member, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
end

local function browse(kind, path)
  local entries = archive_entries(kind, path)
  set_lines(entries)
  vim.b.archive_entries = entries
  vim.b.archive_path = path
  vim.b.archive_kind = kind
  if #entries > 0 then
    pcall(api.nvim_buf_set_keymap, 0, 'n', '<CR>', '', {
      callback = function()
        open_member(path, kind)
      end,
      silent = true,
      nowait = true,
      desc = 'Open archive member',
    })
  end
end

local gzip_patterns = {}
for ext in pairs(compressors) do
  gzip_patterns[#gzip_patterns + 1] = '*.' .. ext
end

local tar_patterns = { 'tarfile::*', 'tarfile::*/*' }
for _, ext in ipairs(tar_extensions) do
  tar_patterns[#tar_patterns + 1] = '*' .. ext
end

local zip_patterns = { 'zipfile::*', 'zipfile::*/*' }
for _, ext in ipairs(zip_extensions) do
  zip_patterns[#zip_patterns + 1] = '*' .. ext
end

function M.setup()
  if vim.g.loaded_gzip then
    return
  end
  vim.g.loaded_gzip = 1
  vim.g.loaded_tar = 1
  vim.g.loaded_zip = 1

  local gzip = api.nvim_create_augroup('gzip', { clear = true })
  api.nvim_create_autocmd('BufReadPre', {
    group = gzip,
    pattern = gzip_patterns,
    callback = function()
      vim.bo.bin = true
    end,
  })
  api.nvim_create_autocmd('BufReadCmd', {
    group = gzip,
    pattern = gzip_patterns,
    callback = function(ev)
      set_lines(read_compressed(ev.match))
      vim.bo.bin = true
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = gzip,
    pattern = gzip_patterns,
    callback = function(ev)
      write_compressed(ev.match)
    end,
  })

  local tar = api.nvim_create_augroup('tar', { clear = true })
  api.nvim_create_autocmd('BufReadCmd', {
    group = tar,
    pattern = tar_patterns,
    callback = function(ev)
      browse('tar', ev.match)
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = tar,
    pattern = { 'tarfile::*', 'tarfile::*/*' },
    callback = function()
      error('tar: writing archive members is not supported yet', 0)
    end,
  })

  local zip = api.nvim_create_augroup('zip', { clear = true })
  api.nvim_create_autocmd('BufReadCmd', {
    group = zip,
    pattern = zip_patterns,
    callback = function(ev)
      browse('zip', ev.match)
    end,
  })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = zip,
    pattern = { 'zipfile::*', 'zipfile::*/*' },
    callback = function()
      error('zip: writing archive members is not supported yet', 0)
    end,
  })
end

return M
