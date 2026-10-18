-- TASK-002: LuaJIT embedding conformance
-- Tests that zigvim can run LuaJIT 2.1 code correctly.

local out = {}

-- Check Lua version (should be "Lua 5.1" from LuaJIT)
out.lua_version = _VERSION

-- Check LuaJIT version
if jit then
  out.jit_version = jit.version
else
  out.jit_version = "not LuaJIT"
end

-- Test that we can require modules
local ok, inspect = pcall(require, "inspect")
out.can_require = ok

-- Test math
out.math_pi = math.pi

io.stdout:write(vim.json.encode(out) .. "\n")
