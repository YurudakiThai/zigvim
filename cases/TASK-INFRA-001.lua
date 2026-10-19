-- TASK-INFRA-001: Link libuv in build.zig
-- Test that libuv is properly linked and accessible

-- Test 1: Check that we can access vim.uv (mock implementation)
local result = {}

-- Test vim.uv functions exist
result.has_uv = vim.uv ~= nil
result.has_os_uname = type(vim.uv.os_uname) == "function"
result.has_cwd = type(vim.uv.cwd) == "function"
result.has_os_homedir = type(vim.uv.os_homedir) == "function"

-- Test 2: Call some vim.uv functions
result.uname = vim.uv.os_uname()
result.cwd = vim.uv.cwd()
result.homedir = vim.uv.os_homedir()

-- Test 3: Check that uname returns expected structure
result.uname_has_sysname = type(result.uname) == "table" and result.uname.sysname ~= nil

-- Output as JSON
io.stdout:write(vim.json.encode(result) .. "\n")
