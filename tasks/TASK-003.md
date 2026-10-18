# TASK-003: Ship $VIMRUNTIME/lua

**Priority:** P0 (critical for plugin compatibility)  
**Depends on:** TASK-002 (LuaJIT embed)  
**Estimated time:** 30 minutes for agent  
**Test file:** `cases/TASK-003.lua`

---

## 🎯 Objective

Copy Neovim's `$VIMRUNTIME/lua/` directory into zigvim's runtime path. This gives you:
- `vim.inspect` (for debugging)
- `vim.iter` (iterator utilities)
- `vim.fs` (filesystem utilities)
- `vim.lsp` (LSP client framework)
- 120+ other pure-Lua modules

This is the foundation for plugin compatibility.

---

## 📋 Requirements

### Runtime Path Setup
- Copy `/opt/homebrew/Cellar/neovim/0.12.6/share/nvim/runtime/lua/` to `zigvim/runtime/lua/`
- Set `package.path` to include `runtime/lua/?.lua` and `runtime/lua/?/init.lua`
- Ensure `require("vim.inspect")` works without errors

### CLI Interface
```bash
zigvim --headless --clean --cmd "set rtp+=./runtime" -l <script.lua> -c "qa!"
```

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-003 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "vim_inspect_loaded": true,
  "vim_iter_loaded": true,
  "vim_fs_loaded": true,
  "inspect_output": "{\n  a = 1,\n  b = 2\n}"
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Copy Runtime
```bash
mkdir -p runtime
cp -r /opt/homebrew/Cellar/neovim/0.12.6/share/nvim/runtime/lua runtime/
```

### Set Package Path in Lua
Before running user scripts, execute:
```lua
package.path = package.path .. ";./runtime/lua/?.lua;./runtime/lua/?/init.lua"
```

Or set it in Zig before `luaL_dostring`:
```zig
const set_path = "package.path = package.path .. ';./runtime/lua/?.lua;./runtime/lua/?/init.lua'";
_ = c.luaL_dostring(L, set_path.ptr);
```

### Verify Modules Load
Test that key modules load without errors:
```lua
local ok1, inspect = pcall(require, "vim.inspect")
local ok2, iter = pcall(require, "vim.iter")
local ok3, fs = pcall(require, "vim.fs")
```

---

## ✅ Acceptance Criteria

- [ ] `runtime/lua/vim/inspect.lua` exists
- [ ] `require("vim.inspect")` succeeds without errors
- [ ] `./scripts/verify.sh TASK-003` exits with code 0
- [ ] Commit message: `feat(TASK-003): ship Neovim runtime/lua for plugin compatibility`

---

## 📚 References

- Neovim runtime: `/opt/homebrew/Cellar/neovim/0.12.6/share/nvim/runtime/`
- Lua package.path: https://www.lua.org/pil/8.1.html
- Test file: `cases/TASK-003.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Path separators:** Use `;` on Windows, `:` on Unix. Lua auto-detects, but be careful.
- **Module loading order:** Some modules depend on others. If `vim.lsp` fails, check `vim.lsp.protocol` etc.
- **Licensing:** Neovim runtime is Apache 2.0. Retain `NOTICE` file in `runtime/` directory.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
