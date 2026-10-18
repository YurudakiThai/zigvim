# TASK-005: Basic vim.json

**Priority:** P0 (critical for test harness)  
**Depends on:** TASK-003 (runtime/lua)  
**Estimated time:** 30 minutes for agent  
**Test file:** `cases/TASK-005.lua`

---

## 🎯 Objective

Ensure `vim.json.encode()` and `vim.json.decode()` work correctly. This is needed for:
- The test harness (all test cases output JSON)
- Plugin compatibility (many plugins use vim.json)

Neovim's `vim.json` is a C module. You can either:
1. Port the C code to Zig
2. Use a pure-Lua JSON library (like `json.lua` or `cjson`)
3. Embed Neovim's `vim.json` C module

Option 2 is fastest for now.

---

## 📋 Requirements

### vim.json API
```lua
vim.json.encode(value)  -- returns JSON string
vim.json.decode(string) -- returns Lua value
```

### Supported Types
- Numbers (int, float)
- Strings
- Booleans
- Tables (arrays and objects)
- nil

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-005 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "encode_number": "42",
  "encode_string": "\"hello\"",
  "encode_bool": "true",
  "encode_array": "[1,2,3]",
  "encode_table": "{\"a\":1,\"b\":2}",
  "decode_number": 42,
  "decode_string": "hello",
  "decode_array": [1, 2, 3]
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Use Pure-Lua JSON
Download `json.lua` (single file, MIT license):
```bash
wget https://raw.githubusercontent.com/rxi/json.lua/master/json.lua -O runtime/lua/json.lua
```

Then expose as `vim.json`:
```lua
vim.json = require('json')
```

### Or Port Neovim's vim.json
Neovim's `vim.json` is in `src/nvim/lua/json.c`. It's ~500 lines of C. You can:
1. Compile it as a shared library
2. Load it with `package.loadlib`
3. Or port to Zig

For now, use pure-Lua JSON. Port later if needed.

---

## ✅ Acceptance Criteria

- [ ] `vim.json.encode({1,2,3})` returns `"[1,2,3]"`
- [ ] `vim.json.decode('{"a":1}')` returns `{a = 1}`
- [ ] `./scripts/verify.sh TASK-005` exits with code 0
- [ ] Commit message: `feat(TASK-005): implement vim.json.encode/decode`

---

## 📚 References

- Neovim source: `src/nvim/lua/json.c`
- json.lua: https://github.com/rxi/json.lua
- Test file: `cases/TASK-005.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Number formatting:** `vim.json.encode(42)` must be `"42"`, not `"42.0"`.
- **String escaping:** Must escape `"` and `\` in strings.
- **Array vs object:** `{1,2,3}` is array, `{a=1,b=2}` is object. Don't mix.
- **Nil handling:** `vim.json.encode(nil)` should return `"null"`.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
