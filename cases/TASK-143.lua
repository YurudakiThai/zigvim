-- TASK-143: :augroup / augroup END, `|` between commands, :execute, :messages

vim.g.n143 = 0
vim.cmd('augroup g143')
vim.cmd('autocmd User P143 let g:n143 = g:n143 + 1')
vim.cmd('augroup END')
vim.cmd('autocmd User P143 let g:n143 = g:n143 + 10')
vim.api.nvim_exec_autocmds('User', { pattern = 'P143' })
local after_fire = vim.g.n143
local groups = {}
for _, a in ipairs(vim.api.nvim_get_autocmds({ event = 'User', pattern = 'P143' })) do
  groups[#groups + 1] = a.group_name or 'none'
end
table.sort(groups)

vim.cmd([[augroup g143 | exe "autocmd!" | augroup END]])
local after_clear = #vim.api.nvim_get_autocmds({ group = 'g143' })
vim.cmd([[let g:bar1 = 1 | let g:bar2 = 2]])
vim.cmd([[exe "let g:exe143 = " . (2 + 3)]])
local ok_msg = pcall(vim.cmd, 'messages')

io.stdout:write(vim.json.encode({
  after_fire = after_fire,
  groups = groups,
  after_clear = after_clear,
  ungrouped_left = #vim.api.nvim_get_autocmds({ event = 'User', pattern = 'P143' }),
  bar = { vim.g.bar1, vim.g.bar2 },
  exe = vim.g.exe143,
  messages = ok_msg,
  types = { vim.type_idx, vim.val_idx, vim.types.array, vim.types.float, vim.types.dictionary, vim.types[5], vim.types[6] },
}) .. "\n")
