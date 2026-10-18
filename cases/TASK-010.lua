-- TASK-010: Global/buffer/window/tab variables conformance
-- Tests vim.g, vim.b, vim.w, vim.t.

local out = {}

-- Test vim.g (global)
vim.g.test_global = "global_value"
out.g_set = vim.g.test_global

-- Test vim.b (buffer-local)
vim.b.test_buffer = "buffer_value"
out.b_set = vim.b.test_buffer

-- Test vim.w (window-local)
vim.w.test_window = "window_value"
out.w_set = vim.w.test_window

-- Test persistence (global survives buffer switch)
vim.g.persistent = "global_value"
local buf2 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf2)
out.g_persistent = vim.g.persistent

-- Test buffer isolation (new buffer doesn't have old buffer's vars)
out.b_new_buffer = vim.b.test_buffer  -- Should be nil

io.stdout:write(vim.json.encode(out) .. "\n")
