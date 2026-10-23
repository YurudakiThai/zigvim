-- TASK-135: autocmd event names are case-insensitive; Vim aliases map to canonical events

local ok = {}
for _, e in ipairs({ 'BufWrite', 'Filetype', 'filetype', 'bufreadpost', 'BufCreate', 'bufread', 'NoSuchEvent135' }) do
  local good, err = pcall(vim.api.nvim_create_autocmd, e, { group = vim.api.nvim_create_augroup('g135', { clear = false }), callback = function() end })
  ok[#ok + 1] = good and 'ok' or tostring(err)
end
local stored = {}
for _, a in ipairs(vim.api.nvim_get_autocmds({ group = 'g135' })) do
  stored[#stored + 1] = a.event
end
table.sort(stored)

vim.g.fired135 = 0
vim.api.nvim_create_autocmd('BufRead', { pattern = '*', callback = function() vim.g.fired135 = vim.g.fired135 + 1 end })
vim.api.nvim_exec_autocmds('BufReadPost', { pattern = 'x.txt' })

io.stdout:write(vim.json.encode({
  ok = ok,
  stored = stored,
  fired = vim.g.fired135,
  get_lower = #vim.api.nvim_get_autocmds({ group = 'g135', event = 'filetype' }),
}) .. "\n")
