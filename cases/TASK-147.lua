-- TASK-147: nvim_buf_get_extmarks details for virtual text (the TUI draws 'eol' ones).
vim.fn.setline(1, { 'ab', 'cd' })
local ns = vim.api.nvim_create_namespace('t147')
vim.api.nvim_buf_set_extmark(0, ns, 0, 0, { virt_text = { { 'XY', 'Error' }, { 'Z', { 'A', 'B' } } } })
vim.api.nvim_buf_set_extmark(0, ns, 0, 1, { virt_text = { { 'Q' } }, virt_text_pos = 'right_align' })
vim.api.nvim_buf_set_extmark(0, ns, 1, 0, { hl_group = 'Error', end_col = 1 })
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
for _, m in ipairs(marks) do
  m[4].ns_id = nil
end
io.stdout:write(vim.json.encode({ all = marks, vt = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { type = 'virt_text' }) }) .. "\n")
