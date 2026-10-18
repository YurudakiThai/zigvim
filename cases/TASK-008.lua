-- TASK-008: Current buffer/window state conformance
-- Tests getting and setting current buffer and window.

local out = {}

-- Get initial buffer and window
out.initial_buf = vim.api.nvim_get_current_buf()
out.initial_win = vim.api.nvim_get_current_win()

-- Create a new buffer
local buf2 = vim.api.nvim_create_buf(true, false)

-- Switch to it
vim.api.nvim_set_current_buf(buf2)
out.after_switch_buf = vim.api.nvim_get_current_buf()

-- Verify current buffer changed
out.current_buf_after = vim.api.nvim_get_current_buf()

io.stdout:write(vim.json.encode(out) .. "\n")
