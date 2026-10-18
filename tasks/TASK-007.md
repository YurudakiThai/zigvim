# TASK-007: Buffer Lifecycle APIs

**Priority:** P0 (critical for buffer management)  
**Depends on:** TASK-006 (buf_set_lines)  
**Estimated time:** 2-3 hours for agent  
**Test file:** `cases/TASK-007.lua`

---

## 🎯 Objective

Implement buffer lifecycle APIs:
- `vim.api.nvim_create_buf(listed, scratch)` — create new buffer
- `vim.api.nvim_buf_is_valid(buffer)` — check if buffer is valid
- `vim.api.nvim_buf_delete(buffer, opts)` — delete buffer
- `vim.api.nvim_buf_line_count(buffer)` — get line count

These are needed for buffer management by plugins.

---

## 📋 Requirements

### Function Signatures
```lua
-- Create new buffer
local buf = vim.api.nvim_create_buf(
  listed,   -- boolean: if true, buffer appears in buffer list
  scratch   -- boolean: if true, buffer is not saved to disk
)
-- Returns: buffer handle (integer)

-- Check if buffer is valid
local valid = vim.api.nvim_buf_is_valid(buffer)
-- Returns: boolean

-- Delete buffer
vim.api.nvim_buf_delete(
  buffer,  -- buffer handle
  opts     -- table: {force = boolean}
)

-- Get line count
local count = vim.api.nvim_buf_line_count(buffer)
-- Returns: integer
```

### Edge Cases
1. **Scratch buffers:** `nvim_create_buf(false, true)` creates buffer not backed by file
2. **Listed buffers:** `nvim_create_buf(true, false)` adds to buffer list
3. **Invalid buffer:** After `nvim_buf_delete`, `nvim_buf_is_valid` returns false
4. **Empty buffer:** New buffer has 1 line (empty string)

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-007 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "new_buf_is_valid": true,
  "new_buf_line_count": 1,
  "after_delete_valid": false,
  "scratch_buf_valid": true,
  "scratch_buf_listed": false
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Buffer Handle System
- Use monotonically increasing integers for buffer handles
- Store buffer metadata in a hashmap: `buffer_id -> Buffer`
- `Buffer` struct: `{lines: ArrayList([]const u8), valid: bool, listed: bool, scratch: bool}`

### nvim_create_buf
```zig
fn nvim_create_buf(L: *c.lua_State) c_int {
    const listed = c.lua_toboolean(L, 1) != 0;
    const scratch = c.lua_toboolean(L, 2) != 0;
    
    const buf_id = next_buffer_id;
    next_buffer_id += 1;
    
    var buf = Buffer{
        .lines = ArrayList([]const u8).init(allocator),
        .valid = true,
        .listed = listed,
        .scratch = scratch,
    };
    buf.lines.append("") catch {};  // Empty buffer has 1 empty line
    
    buffer_map.put(buf_id, buf) catch {};
    
    c.lua_pushinteger(L, @intCast(buf_id));
    return 1;
}
```

### nvim_buf_is_valid
```zig
fn nvim_buf_is_valid(L: *c.lua_State) c_int {
    const buf_id = @as(usize, @intCast(c.lua_tointeger(L, 1)));
    if (buffer_map.get(buf_id)) |buf| {
        c.lua_pushboolean(L, if (buf.valid) 1 else 0);
    } else {
        c.lua_pushboolean(L, 0);
    }
    return 1;
}
```

---

## ✅ Acceptance Criteria

- [ ] `nvim_create_buf` returns unique buffer handles
- [ ] `nvim_buf_is_valid` returns true for valid buffers, false for deleted
- [ ] `nvim_buf_delete` marks buffer as invalid
- [ ] `./scripts/verify.sh TASK-007` exits with code 0
- [ ] Commit message: `feat(TASK-007): implement buffer lifecycle APIs`

---

## 📚 References

- Neovim source: `src/nvim/api/buffer.c` (functions `nvim_create_buf`, `nvim_buf_delete`)
- Test file: `cases/TASK-007.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Buffer ID reuse:** Don't reuse buffer IDs immediately. Use monotonic counter.
- **Empty buffer:** New buffer has 1 line (empty string), not 0 lines.
- **Delete semantics:** `nvim_buf_delete` doesn't free memory immediately. Just mark as invalid.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
