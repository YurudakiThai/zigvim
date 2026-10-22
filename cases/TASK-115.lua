-- TASK-115: vim.fn.winsaveview / winrestview round trip

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abc", "def", "ghi" })
vim.api.nvim_win_set_cursor(0, { 2, 1 })
local view = vim.fn.winsaveview()
local keys = vim.tbl_keys(view)
table.sort(keys)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.winrestview(view)
local restored = vim.api.nvim_win_get_cursor(0)

io.stdout:write(vim.json.encode({
  keys = keys,
  lnum = view.lnum,
  col = view.col,
  coladd = view.coladd,
  restored = restored,
}) .. "\n")
