# TASK-012: Simple Autocmds

**Priority:** P0 (critical for plugin events)  
**Depends on:** TASK-011 (event loop)  
**Estimated time:** 4-6 hours for agent  
**Test file:** `cases/TASK-012.lua`

---

## 🎯 Objective

Implement basic autocmd system:
- `vim.api.nvim_create_augroup(name, opts)` — create autocmd group
- `vim.api.nvim_create_autocmd(events, opts)` — create autocmd
- `vim.api.nvim_exec_autocmds(events, opts)` — trigger autocmds manually

Plugins use autocmds to respond to editor events (BufEnter, BufWrite, etc.).

---

## 📋 Requirements

### Function Signatures
```lua
-- Create autocmd group
local group_id = vim.api.nvim_create_augroup(
  "MyGroup",     -- group name
  {clear = true} -- options
)
-- Returns: group ID (integer)

-- Create autocmd
local autocmd_id = vim.api.nvim_create_autocmd(
  "BufEnter",    -- event name (string or array)
  {
    group = "MyGroup",  -- group name or ID
    pattern = "*.lua",  -- file pattern (optional)
    callback = function()
      -- callback function
    end,
  }
)
-- Returns: autocmd ID (integer)

-- Execute autocmds manually
vim.api.nvim_exec_autocmds(
  "User",        -- event name
  {
    pattern = "MyEvent",  -- user-defined pattern
  }
)
```

### Basic Events to Implement
1. **User** — manual trigger (for testing)
2. **BufEnter** — when entering a buffer
3. **BufLeave** — when leaving a buffer

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-012 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "group_created": true,
  "autocmd_created": true,
  "callback_executed": true,
  "multiple_events": 3
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Storage
```zig
const Autocmd = struct {
    id: usize,
    group: usize,
    event: []const u8,
    pattern: ?[]const u8,
    callback: c.lua_State,  // Lua reference
};

var autocmds = ArrayList(Autocmd).init(allocator);
var groups = std.StringHashMap(usize).init(allocator);
```

### nvim_create_augroup
```zig
fn nvim_create_augroup(L: *c.lua_State) c_int {
    const name = c.lua_tostring(L, 1);
    const opts = c.lua_touserdata(L, 2);  // table
    
    const group_id = next_group_id;
    next_group_id += 1;
    
    groups.put(name, group_id) catch {};
    
    c.lua_pushinteger(L, @intCast(group_id));
    return 1;
}
```

### nvim_create_autocmd
```zig
fn nvim_create_autocmd(L: *c.lua_State) c_int {
    const event = c.lua_tostring(L, 1);  // or array
    const opts = c.lua_touserdata(L, 2);  // table with group, pattern, callback
    
    const autocmd_id = next_autocmd_id;
    next_autocmd_id += 1;
    
    // Extract callback from opts table
    // Store in autocmds list
    
    c.lua_pushinteger(L, @intCast(autocmd_id));
    return 1;
}
```

### nvim_exec_autocmds
```zig
fn nvim_exec_autocmds(L: *c.lua_State) c_int {
    const event = c.lua_tostring(L, 1);
    const opts = c.lua_touserdata(L, 2);
    
    // Find all autocmds matching event and pattern
    // Execute their callbacks
    
    return 0;
}
```

---

## ✅ Acceptance Criteria

- [ ] `nvim_create_augroup` creates named group
- [ ] `nvim_create_autocmd` registers callback for event
- [ ] `nvim_exec_autocmds` triggers matching autocmds
- [ ] `./scripts/verify.sh TASK-012` exits with code 0
- [ ] Commit message: `feat(TASK-012): implement autocmd system`

---

## 📚 References

- Neovim source: `src/nvim/autocmd.c` (autocmd implementation)
- Neovim API: `src/nvim/api/autocmd.c` (autocmd APIs)
- Test file: `cases/TASK-012.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Pattern matching:** `*.lua` should match `foo.lua`, not `foo.txt`.
- **Group clearing:** `{clear = true}` should remove existing autocmds in group.
- **Callback execution:** Must execute in Lua state, not Zig.
- **Event ordering:** Multiple autocmds for same event execute in creation order.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
