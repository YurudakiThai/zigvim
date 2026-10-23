# TASK-121: keytrans and sign definitions (AstroNvim astrocore setup)

## Summary

AstroNvim's `astrocore.setup` aborted on `vim.fn.keytrans` (normalising mapping
keys) and then on `vim.fn.sign_define`, so none of its options, mappings,
autocmds or commands were applied. Adds:

- `vim.fn.keytrans` — raw keys to `<>` notation; also accepts zigvim's
  canonical tokens since `nvim_replace_termcodes` emits notation, not bytes.
- `vim.fn.sign_define` / `sign_getdefined` / `sign_undefine` (definitions only).

## Test

`cases/TASK-121.lua`: `keytrans(replace_termcodes(lhs))` for AstroNvim-style
keys and `keytrans` on raw bytes.

## Result (AstroNvim template)

keymaps missing 184→5, commands missing 9→2, augroups missing 24→few, options IDENTICAL.
