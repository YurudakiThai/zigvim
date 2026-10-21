-- TASK-113: startup runtime plugins (netrw, matchparen, archives, tutor, rplugin)
-- and the filetype/ftplugin pipeline they depend on.

local out = {}

-- Commands Neovim defines by loading runtime/plugin/*.vim at startup.
local commands = {
  'DoMatchParen', 'NoMatchParen', 'MatchEnable', 'MatchDisable', 'MatchDebug',
  'Explore', 'Hexplore', 'Lexplore', 'Nexplore', 'Pexplore', 'Sexplore',
  'Texplore', 'Vexplore', 'NetUserPass', 'Nread', 'Nsource', 'Ntree', 'Nwrite',
  'Tutor', 'UpdateRemotePlugins',
}
out.commands = {}
for _, name in ipairs(commands) do
  out.commands[name] = vim.fn.exists(':' .. name)
end

-- Augroups those plugins create.
local groups = {
  'filetypedetect', 'filetypeplugin', 'filetypeindent', 'syntaxset',
  'FileExplorer', 'Network', 'gzip', 'tar', 'zip', 'matchparen',
}
out.groups = {}
for _, name in ipairs(groups) do
  out.groups[name] = pcall(vim.api.nvim_get_autocmds, { group = name }) and 1 or 0
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')

-- Filetype detection and the ftplugin/indent pipeline.
local py = dir .. '/x.py'
vim.fn.writefile({ 'print(1)' }, py)
vim.cmd('edit ' .. py)
out.filetype = vim.bo.filetype
out.syntax = vim.bo.syntax

local rtp = dir .. '/rtp'
vim.fn.mkdir(rtp .. '/ftplugin', 'p')
vim.fn.mkdir(rtp .. '/indent', 'p')
vim.fn.writefile({ 'vim.b.ftplugin_loaded = 1' }, rtp .. '/ftplugin/python.lua')
vim.fn.writefile({ 'vim.b.indent_loaded = 1' }, rtp .. '/indent/python.lua')
vim.opt.runtimepath:prepend(rtp)

local py2 = dir .. '/y.py'
vim.fn.writefile({ 'print(2)' }, py2)
vim.cmd('edit ' .. py2)
out.ftplugin_loaded = vim.b.ftplugin_loaded or 0
out.indent_loaded = vim.b.indent_loaded or 0

-- gzip.vim shows decompressed contents for *.gz buffers.
local src = dir .. '/z.txt'
vim.fn.writefile({ 'hello', 'world' }, src)
vim.fn.system({ 'sh', '-c', 'gzip -c "$1" > "$2"', 'sh', src, dir .. '/z.txt.gz' })
vim.cmd('edit ' .. dir .. '/z.txt.gz')
out.gzip_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

io.stdout:write(vim.json.encode(out) .. '\n')
