-- TASK-004: vim.inspect conformance
-- Tests that vim.inspect is exposed correctly.

local out = {}

-- Check vim exists
out.vim_exists = vim ~= nil

-- Check vim.inspect type
if vim and vim.inspect then
  out.inspect_type = type(vim.inspect)
else
  out.inspect_type = "nil"
end

-- Test vim.inspect on table
if vim and vim.inspect then
  out.inspect_output = vim.inspect({a = 1, b = 2})
else
  out.inspect_output = ""
end

-- Test vim.inspect on array
if vim and vim.inspect then
  out.inspect_array = vim.inspect({1, 2, 3})
else
  out.inspect_array = ""
end

io.stdout:write(vim.json.encode(out) .. "\n")
