# TASK-124: vim.version is the runtime module, reporting 0.12.6

## Summary

zigvim defined `vim.version` as a plain function returning 0.1.0, so
`vim.version.range(...)` crashed. AstroNvim's `_astrolsp.lua` spec does that
at load time; lazy.nvim then dropped the spec (and its `event`), and astrolsp
plus blink.cmp were loaded eagerly at startup. Now the runtime `vim.version`
module is used, backed by `vim.fn.api_info()` reporting the oracle version
(0.12.6, api_level 14).

## Test

`cases/TASK-124.lua`.

## Result (AstroNvim template)

plugins section now matches (astrolsp/blink.cmp lazy as in nvim).
