# TASK-105: Keymap and user-command APIs

**Status:** ✅ Complete
**Priority:** High
**Platform:** All

## 🎯 Objective

Implement `nvim_set_keymap` / `nvim_get_keymap` / `nvim_del_keymap`, their
buffer-local variants, `vim.keymap.set` / `vim.keymap.del`, and
`nvim_create_user_command` / `nvim_del_user_command` / `nvim_get_commands`.

## 📋 Requirements

- Keymap entries match Neovim's shape: `lhs`, `rhs`, `mode`, integer
  `noremap`/`silent` flags, `desc`, and `callback` for Lua functions
- Deleting a missing mapping raises `E31: No such mapping`
- Buffer-local mappings are stored per buffer and returned by
  `nvim_buf_get_keymap`
- User commands receive an `opts` table with `name`, `args`, `line1`, `line2`,
  `bang`; deleting a missing command raises
  `Invalid command (not found): <name>`

## 🧪 Verification

```bash
./scripts/verify.sh TASK-105
```

Case: `cases/TASK-105.lua` — compares against Neovim 0.12.6.
