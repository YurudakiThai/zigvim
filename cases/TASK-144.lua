-- TASK-144: nvim_exec2 output capture, nvim_exec, :autocmd listing, screenrow/screencol

vim.api.nvim_create_augroup('gq144', {})
vim.api.nvim_create_autocmd('User', { group = 'gq144', pattern = 'Pq', command = 'echo 5' })
io.stdout:write(vim.json.encode({
  out = vim.api.nvim_exec2('echo 1 | echo 2', { output = true }).output,
  none = vim.api.nvim_exec2('let g:y = 1', { output = true }).output,
  nooutput = next(vim.api.nvim_exec2('let g:x = 1', {})) == nil,
  listing = (vim.api.nvim_exec2('au gq144 User Pq', { output = true }).output:gsub('\n\tLast set from.*', '')), -- no script tracking
  exec_true = vim.api.nvim_exec('echo 42', true),
  exec_false = vim.api.nvim_exec('let g:z144 = 1', false),
  screen = { vim.fn.screenrow(), vim.fn.screencol() },
}) .. "\n")
