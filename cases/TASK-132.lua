-- TASK-132: strdisplaywidth() expands tabs from {col}; virtcol()

local w = {
  vim.fn.strdisplaywidth('\tab'), vim.fn.strdisplaywidth('x\t'), vim.fn.strdisplaywidth('\t', 3),
  vim.fn.strdisplaywidth('a\tb', 6), vim.fn.strdisplaywidth('héllo'), vim.fn.strdisplaywidth('日本'),
}
vim.bo.tabstop = 4
w[#w + 1] = vim.fn.strdisplaywidth('\tab')
vim.bo.tabstop = 8

vim.api.nvim_buf_set_lines(0, 0, -1, false, { '\tab', 'héllo', '', 'a日b' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local v = { vim.fn.virtcol('.') }
vim.api.nvim_win_set_cursor(0, { 1, 1 })
v[#v + 1] = vim.fn.virtcol('.')
for _, e in ipairs({ '$', { 1, 1 }, { 1, 2 }, { 2, 3 }, { 2, 4 }, { 3, 1 }, { 2, '$' }, { 9, 1 }, { 4, 2 }, { 4, 3 }, { 4, 5 } }) do
  v[#v + 1] = vim.fn.virtcol(e)
end

io.stdout:write(vim.json.encode({
  width = w,
  virtcol = v,
  list = { vim.fn.virtcol({ 1, 1 }, 1), vim.fn.virtcol({ 4, 2 }, 1), vim.fn.virtcol({ 9, 1 }, 1) },
}) .. "\n")
