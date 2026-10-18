# TASK-006: Implement `nvim_buf_set_lines` and `nvim_buf_get_lines`

**Priority:** P0 (critical for buffer model)  
**Depends on:** TASK-001 (bootstrap), TASK-002 (LuaJIT embed)  
**Estimated time:** 2-4 hours for agent  
**Test file:** `cases/TASK-006.lua`

---

## 🎯 Objective

Implement two core buffer APIs in zigvim:
- `vim.api.nvim_buf_set_lines(buf, start, end, strict_indexing, replacement)`
- `vim.api.nvim_buf_get_lines(buf, start, end, strict_indexing)`

These are the foundation for all text editing. Every plugin that modifies buffers uses them.

---

## 📋 Requirements

### Function Signatures (from real nvim)
```lua
-- Set lines in buffer
vim.api.nvim_buf_set_lines(
  buffer,           -- Buffer handle (0 = current)
  start,            -- 0-based start line (inclusive)
  end,              -- 0-based end line (exclusive, -1 = last line)
  strict_indexing,  -- boolean: true = error on out-of-range
  replacement       -- array of strings
)

-- Get lines from buffer
local lines = vim.api.nvim_buf_get_lines(
  buffer,           -- Buffer handle (0 = current)
  start,            -- 0-based start (inclusive)
  end,              -- 0-based end (exclusive, -1 = last line)
  strict_indexing   -- boolean: true = error on out-of-range
)
```

### Edge Cases (from test case)
1. **Replace entire buffer:** `nvim_buf_set_lines(0, 0, -1, false, {"line1", "line2"})`
2. **Insert in middle:** `nvim_buf_set_lines(0, 1, 1, false, {"inserted"})`
3. **Replace range:** `nvim_buf_set_lines(0, 0, 2, false, {"replaced"})`
4. **Delete range:** `nvim_buf_set_lines(0, 1, 3, false, {})`
5. **Unicode handling:** Must preserve UTF-8 (e.g., `β-greek`)
6. **Return value:** `nvim_buf_get_lines` returns array of strings

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-006 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "after_delete": ["replaced"],
  "after_insert": ["alpha", "inserted", "β-greek", "third line"],
  "after_replace": ["replaced", "β-greek", "third line"],
  "buffer_is_valid": true,
  "line_count": 1,
  "lines": ["alpha", "β-greek", "third line"]
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Data Structure
- Use a **rope** or **gap buffer** for efficient line insertion/deletion.
- Store lines as array of strings (simple but O(n) for middle inserts).

### Index Translation
- Lua uses 0-based indexing for these APIs.
- `-1` means "last line" (like Python slices).
- Convert to internal 0-based or 1-based as needed.

### Error Handling
- If `strict_indexing=true` and indices out of range, raise Lua error.
- If `strict_indexing=false`, clamp to valid range.

### Integration with Lua
- Register the C/Zig function in the `vim.api` table.
- Use LuaJIT FFI or C API to expose to Lua.

---

## ✅ Acceptance Criteria

- [ ] `./scripts/verify.sh TASK-006` exits with code 0.
- [ ] Output matches real nvim exactly (JSON deep-equal).
- [ ] No crashes or memory leaks.
- [ ] Commit message: `feat(TASK-006): implement nvim_buf_set_lines/get_lines`

---

## 📚 References

- Neovim source: `src/nvim/api/buffer.c` (functions `nvim_buf_set_lines`, `nvim_buf_get_lines`)
- Test file: `cases/TASK-006.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Indexing confusion:** Neovim uses 0-based for start, but -1 for "end of buffer". Double-check translation.
- **String encoding:** LuaJIT uses UTF-8. Ensure Zig handles UTF-8 correctly (no ASCII assumptions).
- **Buffer handle:** `0` means "current buffer". Resolve to actual buffer ID before operating.
- **Strict indexing:** When `false`, clamp indices to `[0, line_count]`. When `true`, raise error if out of range.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
