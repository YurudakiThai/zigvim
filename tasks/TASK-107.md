# TASK-107: Autocmd API

**Status:** ✅ Complete
**Priority:** High
**Platform:** All

## 🎯 Objective

Implement real autocmd storage and dispatch instead of the previous stubs:
`nvim_create_augroup`, `nvim_create_autocmd`, `nvim_get_autocmds`,
`nvim_del_autocmd`, `nvim_clear_autocmds`, and `nvim_exec_autocmds`.

## 📋 Requirements

- Augroups are stable by name and support `clear`
- Autocmds accept one event or a list, a pattern (string or list), a buffer,
  a Lua callback or a Vim `command`, plus `once`, `nested`, `desc`, `group`
- `nvim_exec_autocmds` passes `{id, event, match, buf, file, data}` to callbacks
  and executes `command` autocmds through the command parser
- `once` autocmds are removed after their first run
- Unknown event names raise `Invalid 'event': '<name>'`
- Listing flattens multi-event autocmds into one entry per event and sorts by
  event name then id, matching Neovim

## 🧪 Verification

```bash
./scripts/verify.sh TASK-107
```

Case: `cases/TASK-107.lua`.
