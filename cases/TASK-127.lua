-- TASK-127: built-in :lsp command and nvim_parse_cmd basics

local p = vim.api.nvim_parse_cmd('lsp enable lua_ls', {})
local ok_bad, err_bad = pcall(vim.api.nvim_parse_cmd, 'notacommandxyz', {})
vim.lsp.config('dummy127', { cmd = { 'false' }, filetypes = { 'nothing127' } })
vim.cmd('lsp enable dummy127')
local enabled = vim.lsp.is_enabled('dummy127')
vim.cmd('lsp disable dummy127')

io.stdout:write(vim.json.encode({
  exists = vim.fn.exists(':lsp'),
  cmd = p.cmd,
  args = p.args,
  bang = p.bang,
  bang2 = vim.api.nvim_parse_cmd('edit! foo.txt', {}).bang,
  bad = { ok_bad, err_bad },
  enabled = enabled,
  disabled = vim.lsp.is_enabled('dummy127'),
}) .. "\n")
