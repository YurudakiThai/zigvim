# TASK-128..132: APIs plugins hit when the TUI opens a file

## Summary

`zigvim file.txt` with a real LazyVim config errored in oil.nvim
(`nvim_tabpage_list_wins`). A pty sweep (open a file, edit, write) found the
rest; the headless `distro_diff` never reached them because UIEnter/VeryLazy
plugins only load with a UI. Each item matches Neovim 0.12.6:

- TASK-128 tabpage/window: `nvim_tabpage_list_wins`, `nvim_win_get_tabpage`,
  `nvim_tabpage_set_win`, `nvim_set_current_tabpage` (single-tab model).
- TASK-129 `vim.fn.maparg`, `vim.fn.sha256`, `vim.fn.findfile`,
  `vim.fn.chdir` / `nvim_set_current_dir` / `:cd`, `nvim_get_hl_by_name`,
  `vim.opt.<boolean/number>` is an Option object with `:get()`, `vim.w[id]` /
  `vim.t[id]`, `:nohlsearch` / `:redraw`, `vim.cmd()` returns `''`.
- TASK-130 `vim.fn.indent`, `nvim_win_get_config` (normal window),
  `vim.fn.getbufinfo`; `nvim_create_buf` applies {listed} and {scratch}.
- TASK-131 `prevnonblank` / `nextnonblank`, `vim.uri_*` on `vim`, Vimscript
  `:autocmd[!] [group] {events} {pat} [++once] [++nested] {cmd}`, `:let` /
  `:echo` evaluate Vimscript (`nvim_eval`), `nvim_clear_autocmds` by group name.
- TASK-132 `strdisplaywidth` expands tabs from {col}; `vim.fn.virtcol`.
- `runtime/filetype.lua` stand-in (lazy.nvim sources it first); treesitter stub
  has `query.add_predicate` / `add_directive`.

## Remaining (subsystems, not single APIs)

- `vim.uv` has no `spawn` / pipes: gitsigns, `vim.system`, mason installs.
- No tree-sitter: highlighting and folds from parsers.
