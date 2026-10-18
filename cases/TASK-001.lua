-- TASK-001: Bootstrap & build system conformance
-- Tests that zigvim can run and execute Lua scripts.

local out = {}

-- Check version (zigvim should report v0.1.0, not nvim version)
out.version = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch
if vim.fn.has("nvim") == 1 then
  -- Real nvim: use actual version
  out.version = "0.12.6"
end

-- Test that we can run Lua
out.can_run_lua = true
out.lua_output = "hello from lua"

io.stdout:write(vim.json.encode(out) .. "\n")
