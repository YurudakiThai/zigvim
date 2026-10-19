# TASK-101: Window, tabpage, cursor, and current-line API

## Objective
Implement the window/tabpage handles and cursor/current-line operations that
plugins use most often, matching Neovim 0.12.6.

## APIs
- `nvim_list_wins`, `nvim_get_current_win`, `nvim_set_current_win`
- `nvim_win_get_buf`, `nvim_win_set_buf`
- `nvim_win_get_cursor`, `nvim_win_set_cursor`
- `nvim_win_get_height`, `nvim_win_get_width`, `nvim_win_get_position`,
  `nvim_win_get_number`, `nvim_win_is_valid`
- `nvim_list_tabpages`, `nvim_get_current_tabpage`,
  `nvim_tabpage_get_number`, `nvim_tabpage_get_win`, `nvim_tabpage_is_valid`
- `nvim_get_current_line`, `nvim_set_current_line`, `nvim_del_current_line`
- `nvim_get_mode`

## Acceptance
- `cases/TASK-101.lua` matches Neovim under `./scripts/verify.sh TASK-101`.
- Buffer handle `0` means the current buffer everywhere.
- A single 1000 window and tabpage 1 mirror Neovim's headless defaults
  (22 rows, 80 columns).
