# TASK-004: Lua Host & vim.inspect

**Priority:** P0 (critical for debugging)  
**Depends on:** TASK-003 (runtime/lua)  
**Estimated time:** 1 hour for agent  
**Test file:** `cases/TASK-004.lua`

---

## 🎯 Objective

Create the `vim` global table and expose `vim.inspect` from the runtime. This is the minimal Lua host that plugins expect.

Plugins call `vim.inspect(obj)` to pretty-print tables. You must:
- Create the `vim` global
- Load `vim.inspect` from runtime
- Expose it as `vim.inspect`

---

## 📋 Requirements

### vim Global Table
```lua
vim = {
  inspect = <function>,
  version = function() return {major=0, minor=1, patch=0} end,
}
```

### vim.inspect Behavior
```lua
vim.inspect({a = 1, b = 2})
-- Returns: "{\n  a = 1,\n  b = 2\n}"
```

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-004 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "vim_exists": true,
  "inspect_type": "function",
  "inspect_output": "{\n  a = 1,\n  b = 2\n}",
  "inspect_array": "{ 1, 2, 3 }"
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Create vim Global
In Zig, after loading Lua:
```zig
// Create vim table
c.lua_newtable(L);

// Add vim.inspect
c.luaL_dostring(L, "vim = vim or {}");
c.luaL_dostring(L, "vim.inspect = require('vim.inspect')");
```

Or in Lua bootstrap:
```lua
vim = vim or {}
vim.inspect = require('vim.inspect')
```

### Test vim.inspect
```lua
local result = vim.inspect({a = 1, b = 2})
-- Should be "{\n  a = 1,\n  b = 2\n}"
```

---

## ✅ Acceptance Criteria

- [ ] `vim` global exists in Lua
- [ ] `vim.inspect` is a function
- [ ] `./scripts/verify.sh TASK-004` exits with code 0
- [ ] Commit message: `feat(TASK-004): create vim global and expose vim.inspect`

---

## 📚 References

- Neovim source: `src/nvim/lua/stdlib.c` (creates vim global)
- Test file: `cases/TASK-004.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **vim.inspect format:** Must match exact formatting (newlines, indentation). Don't write your own.
- **Global scope:** `vim` must be a global, not a local. Use `_G.vim = ...`.
- **Error handling:** If `require('vim.inspect')` fails, the task fails. Fix runtime path first.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
