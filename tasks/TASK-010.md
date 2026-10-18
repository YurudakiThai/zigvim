# TASK-010: Global Variables & Scopes

**Priority:** P0 (critical for plugin state)  
**Depends on:** TASK-009 (options)  
**Estimated time:** 1-2 hours for agent  
**Test file:** `cases/TASK-010.lua`

---

## 🎯 Objective

Implement variable scopes:
- `vim.g.<name>` — global variables
- `vim.b.<name>` — buffer-local variables
- `vim.w.<name>` — window-local variables
- `vim.t.<name>` — tab-local variables

Plugins use these extensively for storing state.

---

## 📋 Requirements

### Variable Scope APIs
```lua
-- Global variables
vim.g.my_var = "value"
local val = vim.g.my_var

-- Buffer-local variables
vim.b.my_var = "value"
local val = vim.b.my_var

-- Window-local variables
vim.w.my_var = "value"
local val = vim.w.my_var

-- Tab-local variables
vim.t.my_var = "value"
local val = vim.t.my_var
```

### Behavior
- **vim.g:** Shared across all buffers/windows/tabs
- **vim.b:** Per-buffer (each buffer has its own set)
- **vim.w:** Per-window (each window has its own set)
- **vim.t:** Per-tab (each tab has its own set)

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-010 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "g_set": "global_value",
  "b_set": "buffer_value",
  "w_set": "window_value",
  "g_persistent": "global_value",
  "b_new_buffer": null
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Storage
```zig
var global_vars = std.StringHashMap(Value).init(allocator);
var buffer_vars = std.AutoHashMap(usize, std.StringHashMap(Value)).init(allocator);
var window_vars = std.AutoHashMap(usize, std.StringHashMap(Value)).init(allocator);
```

### vim.g Metatable
```lua
vim.g = setmetatable({}, {
    __index = function(_, key)
        return zigvim_get_var("g", key)
    end,
    __newindex = function(_, key, value)
        zigvim_set_var("g", key, value)
    end,
})
```

### vim.b Metatable
```lua
vim.b = setmetatable({}, {
    __index = function(_, key)
        local buf = vim.api.nvim_get_current_buf()
        return zigvim_get_var("b", buf, key)
    end,
    __newindex = function(_, key, value)
        local buf = vim.api.nvim_get_current_buf()
        zigvim_set_var("b", buf, key, value)
    end,
})
```

---

## ✅ Acceptance Criteria

- [ ] `vim.g.x = "val"` sets global variable
- [ ] `vim.b.x = "val"` sets buffer-local variable
- [ ] `vim.w.x = "val"` sets window-local variable
- [ ] `./scripts/verify.sh TASK-010` exits with code 0
- [ ] Commit message: `feat(TASK-010): implement global/buffer/window/tab variables`

---

## 📚 References

- Neovim source: `src/nvim/api/vim.c` (variable APIs)
- Test file: `cases/TASK-010.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Nil handling:** `vim.g.unknown` should return nil, not error.
- **Scope isolation:** Buffer variables don't leak between buffers.
- **Type support:** Support numbers, strings, booleans, tables. Don't support functions yet.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
