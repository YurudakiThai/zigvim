# TASK-125: built-in highlight groups and Neovim nvim_set_hl semantics

## Summary

- zigvim started with no highlight groups; Neovim has 384 built-in ones.
  `src/lua/vim/_default_hl.lua` is generated from the oracle
  (`nvim --headless --clean -l scripts/gen_default_hl.lua`), dark and light,
  and applied at startup and on `:highlight clear`.
- `nvim_set_hl` replaces the group (merges only with `update = true`);
  `default = true` keeps an already-defined group; `ctermfg`/`ctermbg`/`blend`
  are kept.
- `nvim_get_hl(..., { link = false })` resolves the link chain.
- `vim.fn.hlexists` (case-insensitive, true for cleared user groups).
- `:highlight clear [group]` and `:highlight [default] link a b`.

AstroNvim's heirline config needed `hlexists` and resolved links to build its
statusline colours.

## Test

`cases/TASK-125.lua`.

## Notes

shortcut: changing 'background' after startup does not reload the defaults;
`:highlight Group guifg=...` attribute arguments are ignored.
