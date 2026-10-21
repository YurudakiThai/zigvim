# TASK-113: Startup runtime plugins (netrw, matchparen, archives, tutor, rplugin)

**Priority:** P0
**Depends on:** TASK-112
**Estimated time:** 4 hours for agent
**Test file:** `cases/TASK-113.lua`

---

## 🎯 Objective

Neovim loads its Vimscript runtime plugins at startup. zigvim has no Vimscript
engine, so these are reimplemented in Lua under `runtime/lua/vim/_*.lua`. This
case pins the observable startup surface: the commands and augroups those
plugins create, filetype detection, the ftplugin/indent pipeline, and gzip
reading.

---

## 📋 Requirements

### Commands defined at startup

`DoMatchParen`, `NoMatchParen`, `MatchEnable`, `MatchDisable`, `MatchDebug`,
`Explore`, `Hexplore`, `Lexplore`, `Nexplore`, `Pexplore`, `Sexplore`,
`Texplore`, `Vexplore`, `NetUserPass`, `Nread`, `Nsource`, `Ntree`, `Nwrite`,
`Tutor`, `UpdateRemotePlugins` — all must report `exists(':Cmd') == 2`.

### Augroups created at startup

`filetypedetect`, `filetypeplugin`, `filetypeindent`, `syntaxset`,
`FileExplorer`, `Network`, `gzip`, `tar`, `zip`, `matchparen`.

### Filetype pipeline

1. Opening `x.py` sets `filetype=python` and `syntax=python`.
2. A Lua `ftplugin/python.lua` and `indent/python.lua` on the runtimepath run.

### Archives

`gzip -c` output written to `z.txt.gz` opens as the decompressed text.

---

## 🔍 Verification

```bash
./scripts/verify.sh TASK-113 --nvim-only --show-output   # oracle
./scripts/verify.sh TASK-113                             # zigvim must match
```

---

## ✅ Acceptance Criteria

- [ ] `./scripts/verify.sh TASK-113` exits with code 0.
- [ ] Output matches real nvim exactly (deep-equal JSON).
- [ ] `python3 scripts/distro_diff.py` still reports IDENTICAL.

---

## 📚 References

- Neovim runtime: `runtime/plugin/{matchparen,tutor,rplugin}.vim`,
  `runtime/pack/dist/opt/{netrw,matchit}`, `runtime/plugin/{gzip,tarPlugin,zipPlugin}.vim`
- Implementation: `runtime/lua/vim/_netrw.lua`, `_matchparen.lua`,
  `_matchit_stub.lua`, `_archives.lua`, `_tutor.lua`, `_remote.lua`
- `docs/DISTRO-LOOP.md` section 6 (stub register)

---

*Task created: 2026-10-21*
