-- TASK-138: buffer/file marks API, getmarklist(), winbufnr()

vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abc', 'def', 'ghi' })
local b = vim.api.nvim_get_current_buf()
local r = {}
r.unset = vim.api.nvim_buf_get_mark(0, 'a')
r.set = vim.api.nvim_buf_set_mark(0, 'a', 2, 1, {})
vim.api.nvim_buf_set_mark(b, 'c', 3, 0, {})
r.get = vim.api.nvim_buf_get_mark(b, 'a')
r.list = vim.fn.getmarklist(b)
r.list0 = vim.fn.getmarklist(0)
r.del = { vim.api.nvim_buf_del_mark(0, 'c'), vim.api.nvim_buf_del_mark(0, 'c') }
r.bad_line = { pcall(vim.api.nvim_buf_set_mark, 0, 'a', 9, 0, {}) }
r.bad_name = { pcall(vim.api.nvim_buf_get_mark, 0, 'ab') }
r.file = vim.api.nvim_buf_set_mark(0, 'A', 1, 0, {})
r.file_get = vim.api.nvim_buf_get_mark(0, 'A')
r.global = vim.fn.getmarklist()
r.winbufnr = { vim.fn.winbufnr(0) == b, vim.fn.winbufnr(vim.api.nvim_get_current_win()) == b, vim.fn.winbufnr(1) == b, vim.fn.winbufnr(9999) }
io.stdout:write(vim.json.encode(r) .. "\n")
