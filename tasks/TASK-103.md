# TASK-103: File edit/write commands and basic vim.fn

## Objective
Make zigvim useful as a scriptable editor: open, modify, write, and reload
files through `vim.cmd` with Neovim-compatible names.

## Requirements
- `vim.cmd` / `nvim_command` support `edit`, `write`, `wq`, `x`, `q`, `qa`,
  `enew`, `set`, `setlocal`, `lua`, `let g:...`, `echo`, and `silent`.
- `edit` loads existing files, creates empty buffers for new paths, normalises
  CRLF, and keeps a trailing newline on write.
- `write` writes the current buffer and clears the modified flag.
- Basic `vim.fn`: `stdpath`, `getcwd`, `expand`, `fnamemodify`,
  `filereadable`, `getenv`, `exists`.
- CLI: `zigvim <file> [-c <command> ...]`, `--clean`, `-u NONE|file`,
  `--headless` (accepted), and `init.lua` loading from `stdpath('config')`
  when no `-l` script is given.

## Acceptance
- `cases/TASK-103.lua` matches Neovim under `./scripts/verify.sh TASK-103`.
- `zigvim file -c 'lua ...' -c 'write'` edits the file on disk.
