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

## Round 2 (after the first blind critic: distinguishable on 7/7 files)

- TASK-141 `on_lines` gets resolved 0-based line numbers (LSP incremental sync
  asserted on -1); `nvim_get_option_info2` / `nvim_get_all_options_info` from
  oracle-generated metadata (scripts/gen_options_info.lua); `vim.fn.bufloaded`
  (format-on-save went through it and failed).
- TASK-142 `vim.str_utf_start/end/pos`; `bufadd`/`bufload` with unloaded
  buffers; `buflisted` honours 'buflisted'; vim.glob/ui/snippet/provider load lazily.
- TASK-143 `:augroup` / `augroup END`, `|` between commands, `:execute`,
  `:messages`; `vim.type_idx` / `vim.val_idx` / `vim.types`.
- TASK-144 `nvim_exec2({output = true})` captures :echo and :autocmd listings;
  `nvim_exec`; `screenrow` / `screencol`.
- Embedded prelude/TUI load under real chunk names, so tracebacks no longer print
  the whole source.

Sweep (7 filetypes, real LazyVim config): zigvim-only errors 5 → 0.

## Round 3 (after critic 2: distinguishable on 8/8 files)

- TASK-145 `getqflist({efm, lines})`: 'errorformat' parser (src/lua/vim/_efm.lua),
  identical to Neovim on every errorformat used by nvim-lint's linters
  (from_errorformat was broken, which also changed what markdown format-on-save
  wrote). `nvim_buf_clear_namespace` honours `-1` / buffer 0 (stale diagnostic
  signs on fixed files).
- TASK-146 `vim.diff` `linematch`, ported from Neovim's linematch.c (gitsigns
  hunk shapes after edits).
- Undo/redo summaries ("1 line less; before #2  0 seconds ago", "Already at
  oldest change"), a message history for `:messages`, Neovim's default
  `vim.notify` (nvim_echo with history, no "ERROR:" prefix), and messages shown on
  the TUI's message line instead of written over the screen.
