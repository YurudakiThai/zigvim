# TASK-127: Neovim startup event order; built-in :lsp; nvim_parse_cmd

## Summary

- Startup order now follows Neovim: `BufEnter` for the first buffer, the `-c`
  commands, then `VimEnter` (skipped when a `-c` command quits), and
  `UIEnter` only when the TUI attaches — never in `--headless`. `-l` scripts
  get none of these. Previously zigvim fired VimEnter/UIEnter before `-c` and
  always, so UIEnter-triggered plugin code (snacks dashboard) ran headless.
- Built-in `:lsp {enable|disable|restart|stop}` via the runtime's
  `vim._core.ex_cmd.ex_lsp`; `exists(':lsp') == 2`. nvim-lspconfig and
  AstroNvim check this to skip their legacy `:LspInfo`/`:LspLog`/`:LspStart`.
- Minimal `nvim_parse_cmd` (name, bang, whitespace args, default mods).

## Test

`cases/TASK-127.lua`.

## Remaining AstroNvim differences (not zigvim bugs or out of scope)

- `n <C-J>`/`<NL>`: nondeterministic upstream (astrocore renames keys while
  iterating with `pairs`).
- astroui.folding / AstroFoldInfo / `nvim.treesitter.query_cache_reset`:
  present in nvim in ~3 of 4 runs (timing of treesitter attach).
- mason-registry.api: mason's async registry refresh (network) during startup.
- rtp_count 13 vs 11: `pack/dist/opt/matchit` (needs `:packadd`) and
  `lib/nvim` (Neovim's parser dir).
