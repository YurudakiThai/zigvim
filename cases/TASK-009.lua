-- TASK-009: Option system conformance
-- Tests vim.o and vim.opt for basic options.

local out = {}

-- Check default values
out.default_number = vim.o.number
out.default_wrap = vim.o.wrap
out.default_tabstop = vim.o.tabstop

-- Set options
vim.o.number = true
out.after_set_number = vim.o.number

vim.o.tabstop = 4
out.after_set_tabstop = vim.o.tabstop

-- Test vim.opt (should work same as vim.o for simple options)
vim.opt.shiftwidth = 4
out.opt_tabstop = vim.o.shiftwidth

io.stdout:write(vim.json.encode(out) .. "\n")
