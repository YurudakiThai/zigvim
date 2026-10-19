# TASK-102: Buffer names, modified flag, and local options

## Objective
Match Neovim's buffer metadata and the option proxies used by plugins.

## Requirements
- `nvim_buf_get_name` / `nvim_buf_set_name`
  - Relative names resolve to absolute paths rooted at the cwd.
  - Existing path components are canonicalised (`/tmp` -> `/private/tmp`).
  - `expand('%')` keeps the name as the user supplied it.
- `modified` flag is false after creation, true after line edits, and can be
  cleared by setting `vim.bo.modified = false`.
- `vim.bo`, `vim.bo[buf]`, `vim.wo`, `vim.o`, and `vim.opt` read/write a shared
  option registry; `vim.opt_local` / `vim.opt_global` are aliases.

## Acceptance
- `cases/TASK-102.lua` matches Neovim under `./scripts/verify.sh TASK-102`.
