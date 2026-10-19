-- TASK-102: Buffer names, modified flag, and local options conformance

local out = {}

out.name0 = vim.api.nvim_buf_get_name(0)
vim.api.nvim_buf_set_name(0, "zz_test_buf.txt")
out.name1 = vim.api.nvim_buf_get_name(0)
out.modified0 = vim.bo.modified
vim.api.nvim_buf_set_lines(0, 0, -1, false, {"x"})
out.modified1 = vim.bo.modified
local ok = pcall(function() vim.bo.modified = false end)
out.clear_ok = ok
out.modified2 = vim.bo.modified
vim.bo.filetype = "lua"
out.ft = vim.bo.filetype
out.ft2 = vim.bo[0].filetype
vim.o.number = true
out.number = vim.o.number
vim.opt.shiftwidth = 2
out.sw = vim.o.shiftwidth

io.stdout:write(vim.json.encode(out) .. "\n")
