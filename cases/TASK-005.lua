-- TASK-005: vim.json conformance
-- Tests that vim.json.encode/decode work correctly.

local out = {}

-- Test encode
out.encode_number = vim.json.encode(42)
out.encode_string = vim.json.encode("hello")
out.encode_bool = vim.json.encode(true)
out.encode_array = vim.json.encode({1, 2, 3})
out.encode_table = vim.json.encode({a = 1, b = 2})

-- Test decode
out.decode_number = vim.json.decode("42")
out.decode_string = vim.json.decode('"hello"')
out.decode_array = vim.json.decode("[1,2,3]")

io.stdout:write(vim.json.encode(out) .. "\n")
