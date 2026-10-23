# TASK-136: decoration providers and the sign column in the TUI

## Summary

gitsigns and diagnostic signs did not show: the TUI never called decoration
providers and had no sign column.

- The TUI calls every `nvim_set_decoration_provider` on each redraw, in
  namespace order: `on_start`, `on_buf`, `on_win(win, buf, toprow, botrow)`,
  `on_line` per visible row, `on_end`; `false` from on_start/on_win skips the rest.
- Sign column from `'signcolumn'` (`yes`, `yes:N`, `auto` when the buffer has
  signs, `no`), left of the numbers; highest-priority sign per line, coloured
  from its `sign_hl_group`. shortcut: one sign per line; `'number'` shows none.
- The TUI redraws on its idle tick when extmarks change, so async work
  (gitsigns' hunks) appears without a keypress.
- Extmark API fixes found on the way: `ns = -1` means all namespaces, `type`
  filter, `ns_id` and default `priority` in details, sign text padded to two
  cells, `{row, -1}` end column means end of line, `buf = 0` is the current buffer.
- `getregionpos` returns one region per line with Neovim's exclusive/eol rules
  (`vim.hl.range` asserted on the old result, which broke `vim.diagnostic.set`).
- `vim.json.encode` follows cjson's sparse-array rule.

## Test

`cases/TASK-136.lua`; screens checked in a pty: gitsigns change/add signs and
diagnostic E/W signs, matching Neovim's sign extmarks.
