-- TASK-006: nvim_buf_set_lines / nvim_buf_get_lines conformance
-- The agent implements this in zigvim, the oracle runs it on real nvim.
-- Output MUST match exactly (deep-equal on JSON).

local out = {}

-- Setup: empty buffer
local buf = vim.api.nvim_get_current_buf()
out.buffer_is_valid = vim.api.nvim_buf_is_valid(buf)

-- Set three lines via the public API (no :normal!, no :put)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"alpha", "β-greek", "third line"})

-- Read them back with the symmetric API
out.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

-- Insert one line in the middle (0-based indexing, end exclusive)
vim.api.nvim_buf_set_lines(buf, 1, 1, false, {"inserted"})
out.after_insert = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

-- Replace a range
vim.api.nvim_buf_set_lines(buf, 0, 2, false, {"replaced"})
out.after_replace = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

-- Delete a range (empty replacement)
vim.api.nvim_buf_set_lines(buf, 1, 3, false, {})
out.after_delete = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

-- Line count
out.line_count = vim.api.nvim_buf_line_count(buf)

io.stdout:write(vim.json.encode(out) .. "\n")
