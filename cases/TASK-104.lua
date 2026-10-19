-- TASK-104: Variable and option API conformance

local out = {}

local ok, err = pcall(function() return vim.api.nvim_get_var("missing_var") end)
out.missing_ok = ok
out.missing_err = tostring(err)

vim.api.nvim_set_var("x", {a = 1})
out.g = vim.api.nvim_get_var("x")
vim.api.nvim_del_var("x")
out.after_del_ok = pcall(function() return vim.api.nvim_get_var("x") end)

vim.api.nvim_buf_set_var(0, "b", 3)
out.b = vim.api.nvim_buf_get_var(0, "b")
out.b_alias = vim.b.b
vim.api.nvim_win_set_var(0, "w", "win")
out.w = vim.api.nvim_win_get_var(0, "w")
vim.api.nvim_tabpage_set_var(0, "t", "tab")
out.t = vim.api.nvim_tabpage_get_var(0, "t")

out.tabstop_default = vim.api.nvim_get_option_value("tabstop", {})
vim.api.nvim_set_option_value("tabstop", 3, {})
out.tabstop_set = vim.api.nvim_get_option_value("tabstop", {})
out.o_tabstop = vim.o.tabstop

out.ft_default = vim.api.nvim_buf_get_option(0, "filetype")
vim.api.nvim_buf_set_option(0, "filetype", "lua")
out.ft_set = vim.api.nvim_buf_get_option(0, "filetype")
out.bo_ft = vim.bo.filetype

out.number_default = vim.api.nvim_win_get_option(0, "number")
vim.api.nvim_win_set_option(0, "number", true)
out.number_set = vim.api.nvim_win_get_option(0, "number")
out.o_number = vim.o.number

io.stdout:write(vim.json.encode(out) .. "\n")
