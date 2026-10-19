# TASK-104: Variable and option APIs

**Status:** ✅ Complete
**Priority:** High
**Platform:** All

## 🎯 Objective

Make `vim.g/b/w/t`, `nvim_*_var`, and the option APIs (`vim.o`, `vim.opt`,
`vim.bo`, `vim.wo`, `nvim_get_option_value`, `nvim_buf_get_option`, ...) behave
like Neovim for the options zigvim supports.

## 📋 Requirements

- Global, buffer, window, and tabpage variables with alias tables (`vim.g`, ...)
- `nvim_get_var` / `nvim_del_var` raise `Key not found: <name>` without a Lua
  source-position prefix, matching Neovim's C API
- Option get/set through both the API and the `vim.*` proxy tables stays in sync
- Buffer and window option accessors resolve buffer `0` / window `0` to current

## 🧪 Verification

```bash
./scripts/verify.sh TASK-104
```

Case: `cases/TASK-104.lua` — compares against Neovim 0.12.6.
