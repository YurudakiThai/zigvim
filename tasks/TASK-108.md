# TASK-108: Autocmds fire on editor actions

**Status:** ✅ Complete
**Priority:** High
**Platform:** All

## 🎯 Objective

Fire the events that editing actions produce so plugin hooks observe the same
sequence as under Neovim: `BufWritePre`/`BufWritePost` around writes, `FileType`
when `filetype` is set, and `BufReadPost`/`BufEnter`/`BufWinEnter` when a file
is edited.

## 📋 Requirements

- `:write` fires `BufWritePre` before writing and `BufWritePost` after the
  buffer is saved and marked unmodified
- Buffer-name patterns (`*.txt`) match the buffer path
- `:set filetype=<ft>` (and `:setlocal`) updates the buffer option and fires
  `FileType` with `<ft>` as the match
- Autocmd `command` hooks can mutate globals through the command parser

## 🧪 Verification

```bash
./scripts/verify.sh TASK-108
```

Case: `cases/TASK-108.lua`.
