-- TASK-101: Window, tabpage, cursor, and current-line conformance

local out = {}

out.list_wins = vim.api.nvim_list_wins()
out.current_win = vim.api.nvim_get_current_win()
out.win_height = vim.api.nvim_win_get_height(0)
out.win_width = vim.api.nvim_win_get_width(0)
out.win_position = vim.api.nvim_win_get_position(0)
out.win_number = vim.api.nvim_win_get_number(0)
out.win_valid = vim.api.nvim_win_is_valid(0)
out.win_buf = vim.api.nvim_win_get_buf(0)

out.list_tabs = vim.api.nvim_list_tabpages()
out.current_tab = vim.api.nvim_get_current_tabpage()
out.tab_number = vim.api.nvim_tabpage_get_number(0)
out.tab_win = vim.api.nvim_tabpage_get_win(0)
out.tab_valid = vim.api.nvim_tabpage_is_valid(0)

vim.api.nvim_buf_set_lines(0, 0, -1, false, {"alpha", "beta"})
vim.api.nvim_win_set_cursor(0, {2, 3})
out.cursor = vim.api.nvim_win_get_cursor(0)
out.current_line = vim.api.nvim_get_current_line()

vim.api.nvim_set_current_line("changed")
out.line_after_set = vim.api.nvim_get_current_line()

vim.api.nvim_del_current_line()
out.lines_after_del = vim.api.nvim_buf_get_lines(0, 0, -1, false)

out.mode = vim.api.nvim_get_mode()

local b2 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, b2)
out.after_win_set_buf = vim.api.nvim_win_get_buf(0)
out.current_buf_after = vim.api.nvim_get_current_buf()

io.stdout:write(vim.json.encode(out) .. "\n")
