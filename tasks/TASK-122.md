# TASK-122: AstroNvim startup — environ, --cmd, runtime file paths

## Summary

- `nvim_get_runtime_file('')` returned `dir .. '/'` for every rtp entry, and
  lazy.nvim feeds that back into 'runtimepath', so each plugin load added
  another `/` (`runtime////////lua/...`). Now matches Neovim: the dir as-is,
  and no doubled `/`.
- `vim.fn.environ()` / `vim.uv.os_environ()` (mason.nvim's process module).
- `nvim_set_decoration_provider` (stored, not invoked — astrolsp inlay hints).
- `--cmd {cmd}` CLI flag: runs before the config is loaded.

## Test

`cases/TASK-122.lua`.

## Result (AstroNvim template)

astrocore.setup completes: colorscheme astrodark, highlights, options, rtp
all match nvim. Remaining: astrolsp needs LPeg (vim.lsp snippet grammar).
