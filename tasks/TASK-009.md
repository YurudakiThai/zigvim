# TASK-009: Option System (vim.o / vim.opt)

**Priority:** P0 (critical for plugin compatibility)  
**Depends on:** TASK-008 (current buffer/window)  
**Estimated time:** 3-4 hours for agent  
**Test file:** `cases/TASK-009.lua`

---

## 🎯 Objective

Implement the option system:
- `vim.o.<option>` — global option access
- `vim.opt.<option>` — option builder (for table-like options)
- Basic options: `number`, `wrap`, `tabstop`, `shiftwidth`, `expandtab`

Plugins use options extensively. This is the foundation for all configuration.

---

## 📋 Requirements

### vim.o API
```lua
-- Get option
local value = vim.o.number  -- boolean

-- Set option
vim.o.number = true

-- Boolean options
vim.o.wrap = false

-- Integer options
vim.o.tabstop = 4
vim.o.shiftwidth = 4

-- String options
vim.o.fileencoding = "utf-8"
```

### vim.opt API
```lua
-- Get option (returns wrapper)
local opt = vim.opt.tabstop

-- Set option
vim.opt.tabstop = 4

-- For table options (not implemented yet)
-- vim.opt.list = { "tab:» ", "trail:·" }
```

### Basic Options to Implement
1. `number` (boolean) — show line numbers
2. `wrap` (boolean) — wrap long lines
3. `tabstop` (integer) — tab width
4. `shiftwidth` (integer) — indent width
5. `expandtab` (boolean) — use spaces instead of tabs

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-009 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "default_number": false,
  "default_wrap": true,
  "default_tabstop": 8,
  "after_set_number": true,
  "after_set_tabstop": 4,
  "opt_tabstop": 4
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Option Storage
```zig
const OptionValue = union(enum) {
    boolean: bool,
    integer: i64,
    string: []const u8,
};

var global_options = std.StringHashMap(OptionValue).init(allocator);

fn init_default_options() !void {
    try global_options.put("number", .{ .boolean = false });
    try global_options.put("wrap", .{ .boolean = true });
    try global_options.put("tabstop", .{ .integer = 8 });
    try global_options.put("shiftwidth", .{ .integer = 8 });
    try global_options.put("expandtab", .{ .boolean = false });
}
```

### vim.o Metatable
In Lua bootstrap:
```lua
vim = vim or {}
vim.o = setmetatable({}, {
    __index = function(_, key)
        return zigvim_get_option(key)
    end,
    __newindex = function(_, key, value)
        zigvim_set_option(key, value)
    end,
})
```

### Zig Functions
```zig
fn zigvim_get_option(L: *c.lua_State) c_int {
    const key = c.lua_tostring(L, 1);
    if (global_options.get(key)) |value| {
        switch (value) {
            .boolean => |b| c.lua_pushboolean(L, if (b) 1 else 0),
            .integer => |i| c.lua_pushinteger(L, @intCast(i)),
            .string => |s| c.lua_pushstring(L, s.ptr),
        }
        return 1;
    } else {
        c.lua_pushnil(L);
        return 1;
    }
}
```

---

## ✅ Acceptance Criteria

- [ ] `vim.o.number` returns default value (false)
- [ ] `vim.o.number = true` sets the option
- [ ] `vim.o.tabstop = 4` sets integer option
- [ ] `./scripts/verify.sh TASK-009` exits with code 0
- [ ] Commit message: `feat(TASK-009): implement option system (vim.o/vim.opt)`

---

## 📚 References

- Neovim source: `src/nvim/api/options.c` (option APIs)
- Neovim options: `src/nvim/options.lua` (option definitions)
- Test file: `cases/TASK-009.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Default values:** Must match Neovim defaults (tabstop=8, not 4).
- **Type checking:** `vim.o.tabstop = "4"` should work (convert string to int).
- **Unknown options:** `vim.o.unknown_option` should return nil, not error.
- **vim.opt vs vim.o:** For simple options, they're interchangeable. vim.opt is for table options.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
