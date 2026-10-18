# API Surface Specification

> Machine-readable contract for vim.api.* functions.
> Agents read this before implementing. Update this when you discover new behavior.

---

## Format

Each API function is documented with:
- **Signature:** Lua call shape
- **Parameters:** types and semantics
- **Return:** what it returns
- **Errors:** when it raises Lua errors
- **Edge cases:** tricky behaviors

---

## vim.api.nvim_buf_set_lines

**Signature:**
```lua
vim.api.nvim_buf_set_lines(buffer, start, end, strict_indexing, replacement)
```

**Parameters:**
- `buffer` (integer): Buffer handle. `0` = current buffer.
- `start` (integer): 0-based start line (inclusive).
- `end` (integer): 0-based end line (exclusive). `-1` = last line.
- `strict_indexing` (boolean): If true, raise error on out-of-range indices. If false, clamp to valid range.
- `replacement` (table): Array of strings to insert.

**Return:** None (void).

**Errors:**
- `E5231: Invalid buffer id` if buffer doesn't exist.
- `E5108: Invalid 'start' or 'end'` if indices out of range and `strict_indexing=true`.

**Edge cases:**
- If `start == end`, this is an insert (no deletion).
- If `replacement` is empty, this is a deletion.
- Negative indices: `-1` means "last line", `-2` means "second to last", etc.

---

## vim.api.nvim_buf_get_lines

**Signature:**
```lua
local lines = vim.api.nvim_buf_get_lines(buffer, start, end, strict_indexing)
```

**Return:** Array of strings (the lines in `[start, end)`).

---

## vim.api.nvim_buf_is_valid

**Signature:**
```lua
local valid = vim.api.nvim_buf_is_valid(buffer)
```

**Return:** Boolean (true if buffer exists and is valid).

---

## vim.api.nvim_buf_line_count

**Signature:**
```lua
local count = vim.api.nvim_buf_line_count(buffer)
```

**Return:** Integer (number of lines in buffer).

---

## vim.api.nvim_get_current_buf

**Signature:**
```lua
local buf = vim.api.nvim_get_current_buf()
```

**Return:** Integer (current buffer handle).

---

## vim.api.nvim_set_current_buf

**Signature:**
```lua
vim.api.nvim_set_current_buf(buffer)
```

**Errors:** Raises error if buffer is invalid.

---

## vim.api.nvim_get_current_win

**Signature:**
```lua
local win = vim.api.nvim_get_current_win()
```

**Return:** Integer (current window handle).

---

## vim.api.nvim_set_current_win

**Signature:**
```lua
vim.api.nvim_set_current_win(window)
```

**Errors:** Raises error if window is invalid.

---

## vim.api.nvim_create_buf

**Signature:**
```lua
local buf = vim.api.nvim_create_buf(listed, scratch)
```

**Parameters:**
- `listed` (boolean): If true, buffer appears in buffer list.
- `scratch` (boolean): If true, buffer is not saved to disk.

**Return:** Integer (buffer handle).

---

## vim.api.nvim_buf_delete

**Signature:**
```lua
vim.api.nvim_buf_delete(buffer, opts)
```

**Parameters:**
- `buffer` (integer): Buffer handle.
- `opts` (table): `{force = boolean}`.

---

## vim.api.nvim_create_augroup

**Signature:**
```lua
local group_id = vim.api.nvim_create_augroup(name, opts)
```

**Return:** Integer (group ID).

---

## vim.api.nvim_create_autocmd

**Signature:**
```lua
local autocmd_id = vim.api.nvim_create_autocmd(events, opts)
```

**Return:** Integer (autocmd ID).

---

## vim.api.nvim_exec_autocmds

**Signature:**
```lua
vim.api.nvim_exec_autocmds(events, opts)
```

---

## How to Add New APIs

When you implement a new `vim.api.nvim_*` function:
1. Run `nvim --headless -c 'lua print(vim.inspect(vim.api.nvim_xxx))' -c 'qa!'` to discover the signature.
2. Add a section to this file following the format above.
3. Write a test case in `cases/TASK-XXX.lua`.
4. Implement in zigvim until `./scripts/verify.sh TASK-XXX` passes.

---

*Last updated: 2026-10-18*
