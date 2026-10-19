# TASK-110: Neovim runtime modules and vim.NIL

**Status:** ✅ Complete
**Priority:** High
**Platform:** All

## 🎯 Objective

Load Neovim's own shipped runtime Lua modules on top of the zigvim API so
plugin-facing helpers behave identically: `vim.tbl_*`, `vim.list_*`,
`vim.split`, `vim.deep_equal`, `vim.fs`, `vim.iter`, `vim.text`, `vim.re`,
`vim.pos`, `vim.range`, `vim.net`, `vim.filetype`, `vim.secure`, `vim.pack`,
`vim.health`, `vim.loader`, `vim.hl`, `vim.diagnostic`, and `vim.lsp`.

## 📋 Requirements

- `vim.NIL` is a real sentinel: JSON encode → `null`, JSON decode of `null`
  → `vim.NIL`, msgpack round-trips, `vim.mpack.encode(nil)` errors like Neovim
- `vim.env`, `vim.v`, `vim.w`, `vim.t` proxies share storage with the API
- `vim.deprecate`, `vim.notify`, `vim.log.levels`, `vim.stricmp`
- `stdpath()` points at Neovim's directories so existing configs load
- Native pieces the modules need: namespaces, `nvim_set_hl`/`nvim_get_hl`,
  extmarks, `nvim_buf_attach`, `vim._with_c`, `vim.fn.getregionpos`, and the
  libuv subset used by `vim.fs` (`os_getenv`, `fs_stat`, `fs_realpath`, ...)

## 🧪 Verification

```bash
./scripts/verify.sh TASK-110
```

Case: `cases/TASK-110.lua` — compares against Neovim 0.12.6.
