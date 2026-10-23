# TASK-119: nvim_set_hl copies gui attributes into cterm

## Summary

When `nvim_set_hl` is called without an explicit `cterm` table, Neovim uses
the gui attributes (bold, italic, ...) for cterm too, so `nvim_get_hl`
returns a `cterm` table. An explicit `cterm` is kept as given. Colorschemes
such as catppuccin rely on this.

## Test

`cases/TASK-119.lua` sets three groups (gui attrs only, gui attrs + explicit
cterm, colour only) and compares the `nvim_get_hl` results.

## Notes

- `scripts/distro_probe.lua` now also snapshots ~28 common highlight groups,
  so `distro_diff.py` catches highlight drift.
