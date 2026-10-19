# TASK-106: API errors and argument validation

**Status:** ✅ Complete
**Priority:** High
**Platform:** All

## 🎯 Objective

Match Neovim's error messages and validation for invalid handles, unknown
options, missing mappings/commands, out-of-range cursor positions, and bad
argument types. Add `nvim_strwidth`.

## 📋 Requirements

- Invalid ids raise `Invalid buffer id: N`, `Invalid window id: N`, or
  `Invalid tabpage id: N` from every API entry point
- API-level errors carry no Lua source-position prefix (`error(msg, 0)`)
- Unknown options raise `Unknown option '<name>'` through `nvim_*_option_value`
  and `Invalid option name: '<name>'` through the legacy buffer/window accessors
- `nvim_command` raises `Vim:E492: ...`; `vim.cmd` adds the same
  `nvim_exec2()` context Neovim does
- `nvim_strwidth` returns terminal cell width (CJK/emoji = 2, combining = 0,
  NUL terminates the string)

## 🧪 Verification

```bash
./scripts/verify.sh TASK-106
```

Case: `cases/TASK-106.lua` — compares against Neovim 0.12.6.
