# TASK-123: vendored LPeg (vim.lpeg)

## Summary

Neovim bundles LPeg; `vim.lsp`'s snippet grammar (and so astrolsp, blink.cmp)
needs it. LPeg 1.1.0 C sources are vendored unmodified in `deps/lpeg`
(MIT, see `deps/lpeg/LICENSE`, provenance and sha256 in `README.zigvim`) and
compiled into zigvim. As in Neovim, it is in `package.loaded.lpeg` at startup
and exposed as `vim.lpeg`; `vim.re` works on top of it.

## Test

`cases/TASK-123.lua`: lpeg patterns, `vim.re`, and `vim.lsp._snippet_grammar`.
