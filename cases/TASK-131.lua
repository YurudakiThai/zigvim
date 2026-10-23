-- TASK-131: prevnonblank/nextnonblank, vim.uri_* on vim, Vimscript :autocmd syntax

vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', '', '  ', 'b', '' })
local pnb = { vim.fn.prevnonblank(3), vim.fn.prevnonblank(1), vim.fn.prevnonblank(0), vim.fn.prevnonblank(99) }
local nnb = { vim.fn.nextnonblank(2), vim.fn.nextnonblank(5), vim.fn.nextnonblank(99), vim.fn.nextnonblank(4) }

vim.api.nvim_buf_set_name(0, '/tmp/zigvim131.txt')
local uri = vim.uri_from_bufnr(0)

vim.g.hits131 = 0
vim.api.nvim_create_augroup('grp131', { clear = true })
vim.cmd([[autocmd grp131 User Ping131 let g:hits131 = g:hits131 + 1]])
vim.cmd([[autocmd User Once131 ++once let g:hits131 = g:hits131 + 10]])
vim.api.nvim_exec_autocmds('User', { pattern = 'Ping131' })
vim.api.nvim_exec_autocmds('User', { pattern = 'Once131' })
vim.api.nvim_exec_autocmds('User', { pattern = 'Once131' })
local after_fire = vim.g.hits131
local in_group = #vim.api.nvim_get_autocmds({ group = 'grp131' })
vim.cmd('autocmd! grp131')
local after_clear = #vim.api.nvim_get_autocmds({ group = 'grp131' })
vim.api.nvim_exec_autocmds('User', { pattern = 'Ping131' })

io.stdout:write(vim.json.encode({
  pnb = pnb,
  nnb = nnb,
  uri = uri,
  uri_fname = vim.uri_to_fname(uri),
  uri_type = type(vim.uri_from_fname),
  hits = { after_fire, vim.g.hits131 },
  groups = { in_group, after_clear },
  cmd = (vim.api.nvim_get_autocmds({ event = 'User', pattern = 'Ping131' })[1] or {}).command,
}) .. "\n")
