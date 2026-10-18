-- TASK-003: Runtime/lua shipping conformance
-- Tests that zigvim can load Neovim's pure-Lua modules.

local out = {}

-- Test that vim.inspect loads
local ok1, inspect = pcall(require, "vim.inspect")
out.vim_inspect_loaded = ok1

-- Test that vim.iter loads
local ok2, iter = pcall(require, "vim.iter")
out.vim_iter_loaded = ok2

-- Test that vim.fs loads
local ok3, fs = pcall(require, "vim.fs")
out.vim_fs_loaded = ok3

-- Test vim.inspect actually works
if ok1 then
  out.inspect_output = inspect({a = 1, b = 2})
else
  out.inspect_output = ""
end

io.stdout:write(vim.json.encode(out) .. "\n")
