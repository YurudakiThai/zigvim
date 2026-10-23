# TASK-126: disable-able runtime plugins; F13+ and same-byte keys in keytrans

## Summary

- netrw, tutor, gzip, tar and zip were started from the prelude, with a
  hard-coded "only in --clean" rule for some of them. Neovim has them as
  `$VIMRUNTIME/plugin/{netrwPlugin,tutor,gzip,tarPlugin,zipPlugin}.vim`, which
  a config disables by name (lazy.nvim `performance.rtp.disabled_plugins`).
  They are now `runtime/plugin/<same name>.lua` stand-ins; `vim._archives`
  has one setup per plugin.
- Runtime plugin loading honours `'loadplugins'` (lazy.nvim sources plugins
  itself, then turns it off) and no longer skips files by `g:loaded_<name>`;
  each file guards itself as in Neovim.
- `nvim_replace_termcodes` knows `<F13>`..`<F37>` and `<NL>`; `keytrans`
  maps control keys that are the same byte as a named key (`<C-J>` → `<NL>`,
  `<C-M>` → `<CR>`, `<C-I>` → `<Tab>`, `<C-[>` → `<Esc>`, `<C-@>` → `<Nul>`).

## Test

`cases/TASK-121.lua` (extended keys). Plugin disabling is covered by
`distro_diff.py` on LazyVim (disables tutor/gzip/tar/zip) and AstroNvim
(disables netrwPlugin/gzip/tar/zip).

## Notes

AstroNvim's `n <C-J>`/`<NL>` diff is nondeterministic upstream: astrocore
renames mapping keys while iterating them with `pairs`.
