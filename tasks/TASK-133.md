# TASK-133..135: processes and pipes (vim.uv), vim.system, vim.diff, event names

## Summary

gitsigns failed on `vim.uv.new_pipe`; `vim.system` did not exist.

- TASK-133 `vim.uv` gains a luv-compatible subset in `src/main.zig`:
  `new_pipe` (`read_start`/`read_stop`/`write`/`shutdown`), `spawn`
  (`args`, `stdio`, `env`, `cwd`, `detached`, `hide`; returns handle + pid or
  luv's `nil, "ENAME: msg", "ENAME"`), `kill` and `process:kill`/`get_pid`,
  a real `new_check`, `new_fs_event` (gitsigns watches `.git`), and the common
  handle methods (`close`, `is_closing`, `is_active`, `ref`, `unref`, `has_ref`)
  also on timers. A closed handle's Lua object stays safe to call (its pointer
  is cleared in the close callback). `vim._core.system` is loaded at startup,
  like `vim._init_packages`, so `vim.system` works (text, stdin, timeout, kill,
  cwd, env, async + `:wait()`).
- TASK-134 `vim.diff` / `vim.text.diff`: Myers line diff in
  `src/lua/vim/_diff.lua` with xdiff-compatible output (`unified`, `indices`,
  `ctxlen`, `on_hunk`, `ignore_*`). shortcut: ambiguous hunks can be placed
  differently from xdiff (48 of 300 random adversarial pairs); every result is a
  correct diff. Exact parity would mean vendoring xdiff (LGPL v2).
- TASK-135 autocmd event names are case-insensitive and Vim's aliases
  (`BufWrite`, `BufRead`, `BufCreate`, `FileEncoding`) map to canonical events;
  gitsigns' attach registers `BufWrite`.
- `vim.json.encode({})` is `[]` (only `vim.empty_dict()` is `{}`), and
  `nvim_get_hl` returns `vim.empty_dict()` when empty, as in Neovim.

## Result

gitsigns attaches, computes hunks and `b:gitsigns_status` in the TUI. Signs are
not drawn yet: gitsigns places them from a decoration provider, which the TUI
does not run.
