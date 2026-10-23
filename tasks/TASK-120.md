# TASK-120: LazyVim yank/put and <expr> maps work in the TUI

## Summary

With the real LazyVim config, `yyp`, `p` after `dd`, and anything using `j`
failed in the TUI. Root causes and fixes:

- `vim.keymap.set` / `nvim_set_keymap` dropped `expr` and `nowait`, and
  `vim.keymap.set` did not default to noremap (Neovim: `noremap = not remap`).
- No Vimscript expression evaluator: added `nvim_eval` / `vim.fn.eval` for
  the subset mapping `<expr>`s use; the TUI evaluates string `<expr>` maps.
- `<Plug>` keys in a noremap rhs are remapped (Neovim behaviour).
- The TUI never ran the libuv loop, so `vim.schedule` callbacks (lazy.nvim's
  `VeryLazy`, which restores LazyVim's `clipboard`) never fired. `_tty_read`
  now pumps the loop while waiting.
- `v:exiting` is `vim.NIL` (lazy.nvim checks it before `VeryLazy`).
- Registers are typed (`getreg(r, 1, 1)`, `getregtype` returns `V`/`v`) and
  shared with the TUI; `"x` prefix, `v:register` and `'clipboard'` default
  register are honoured; `:normal[!]` runs keys through the TUI.

## Test

`cases/TASK-120.lua` checks `nvim_eval` on LazyVim-style expressions, register
types/contents and `v:exiting`. `scripts/tui_smoke.py` (real config) covers
the TUI side: 29/29.
