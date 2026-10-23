# TASK-137..140: opening real files with a real config (gauntlet piece 1)

## Summary

A pty sweep opens .lua/.md/.py/.json/.js/.sh/.c files with the user's LazyVim
config next to Neovim 0.12.6 and counts zigvim-only errors on screen. Fixed:

- TASK-137 `vim.regex` (src/lua/vim/_regex.lua): backtracking Vim-regex engine
  (magic and \v, \c, classes, [], groups, \|, multis incl. \{n,m}/\{-}, \< \>,
  \zs \ze, \@= \@! \@<= \@<!). Neovim's filetype detection uses it (shell files).
  Tested with every vim_regex pattern in Neovim's detect.lua.
- TASK-138 marks API (`nvim_buf_set_mark`/`get_mark`/`del_mark`, file marks),
  `getmarklist`, `winbufnr`.
- TASK-139 `b:changedtick` / `nvim_buf_get_changedtick`, `nvim_buf_set_text`,
  `uv.os_getpid`/`os_getppid`.
- TASK-140 `vim.str_utfindex` / `vim.str_byteindex` and their native helpers.
- `exepath`, `win_findbuf`.
- Opening a file fires Neovim's events: BufReadPre (missing before), BufNewFile
  for a new file, and BufWinEnter/BufEnter in Neovim's order. With that, LazyFile
  plugins (nvim-lspconfig, mason) load as in Neovim.
- TUI fires InsertEnter/InsertLeave (blink.cmp and friends load on them).
- `nvim_buf_attach` callbacks: errors are reported instead of crashing the TUI
  (an LSP on_lines error used to kill it); returning true detaches.

## Remaining

Language servers now attach, which exposes the LSP surface: incremental sync
(`on_lines` must pass resolved line numbers and byte counts),
`nvim_get_option_info2`, `vim.fn.bufloaded`, and more. Next piece.
