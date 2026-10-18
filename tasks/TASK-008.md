# TASK-008: Current Buffer/Window State

**Priority:** P0 (critical for state management)  
**Depends on:** TASK-007 (buffer lifecycle)  
**Estimated time:** 2-3 hours for agent  
**Test file:** `cases/TASK-008.lua`

---

## 🎯 Objective

Implement APIs for managing current buffer and window:
- `vim.api.nvim_get_current_buf()` — get current buffer
- `vim.api.nvim_set_current_buf(buf)` — set current buffer
- `vim.api.nvim_get_current_win()` — get current window
- `vim.api.nvim_set_current_win(win)` — set current window

These are needed for plugins to switch buffers and windows.

---

## 📋 Requirements

### Function Signatures
```lua
-- Get current buffer
local buf = vim.api.nvim_get_current_buf()
-- Returns: buffer handle (integer)

-- Set current buffer
vim.api.nvim_set_current_buf(buffer)
-- buffer: buffer handle

-- Get current window
local win = vim.api.nvim_get_current_win()
-- Returns: window handle (integer)

-- Set current window
vim.api.nvim_set_current_win(window)
-- window: window handle
```

### Edge Cases
1. **Default buffer:** zigvim starts with 1 buffer (handle 1)
2. **Default window:** zigvim starts with 1 window (handle 1000)
3. **Buffer switching:** `nvim_set_current_buf` changes which buffer is active
4. **Invalid buffer:** Setting current to invalid buffer raises error

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-008 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "initial_buf": 1,
  "initial_win": 1000,
  "after_switch_buf": 2,
  "current_buf_after": 2
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Global State
```zig
var current_buffer: usize = 1;
var current_window: usize = 1000;
```

### nvim_get_current_buf
```zig
fn nvim_get_current_buf(L: *c.lua_State) c_int {
    c.lua_pushinteger(L, @intCast(current_buffer));
    return 1;
}
```

### nvim_set_current_buf
```zig
fn nvim_set_current_buf(L: *c.lua_State) c_int {
    const buf_id = @as(usize, @intCast(c.lua_tointeger(L, 1)));
    
    if (buffer_map.get(buf_id)) |buf| {
        if (!buf.valid) {
            c.luaL_error(L, "Invalid buffer id");
            return 0;
        }
        current_buffer = buf_id;
    } else {
        c.luaL_error(L, "Invalid buffer id");
        return 0;
    }
    
    return 0;
}
```

### Window Management
For now, just track a single window. Multiple windows are TASK-XXX later.

---

## ✅ Acceptance Criteria

- [ ] `nvim_get_current_buf` returns current buffer handle
- [ ] `nvim_set_current_buf` changes current buffer
- [ ] `nvim_get_current_win` returns current window handle
- [ ] `./scripts/verify.sh TASK-008` exits with code 0
- [ ] Commit message: `feat(TASK-008): implement current buffer/window APIs`

---

## 📚 References

- Neovim source: `src/nvim/api/vim.c` (functions `nvim_get_current_buf`, `nvim_set_current_buf`)
- Test file: `cases/TASK-008.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Initial state:** zigvim must start with at least 1 buffer and 1 window.
- **Buffer validation:** `nvim_set_current_buf` must check if buffer is valid.
- **Window handles:** Use 1000+ for windows to distinguish from buffers (1-999).

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
