# zigvim

A Neovim-compatible editor written in Zig, with full Lua plugin compatibility.

## 🎯 Goal

Implement a text editor that passes the same Lua scripts that real Neovim 0.12.6 passes,
so plugins like LazyVim, nvim-treesitter, nvim-lspconfig, blink.cmp, gitsigns, oil.nvim,
and 50+ others work without modification.

## 🚀 Quick Start

```bash
# Build
zig build

# Run vibe-coding workflow
cd ~/zigvim
./scripts/verify.sh TASK-001 --nvim-only  # see expected output
./scripts/verify.sh TASK-001                # test zigvim against oracle
./scripts/verify.sh all                     # run all tasks
```

## 📖 Documentation

- **AGENTS.md** — protocol for AI coding agents (copy to `.cursorrules` or `CLAUDE.md`)
- **docs/differential-test-harness.md** — full design report
- **docs/vibe-coding-playbook.md** — vibe coding workflow guide
- **tasks/** — task cards (TASK-001 through TASK-012)
- **specs/api-surface.md** — machine-readable API contract

## 🛠️ Development

See `docs/vibe-coding-playbook.md` for the complete vibe coding workflow.

### Environment

- Zig 0.17.0
- Apple Clang 16.0.0
- macOS Sequoia 15.8.1 (arm64)
- Dependencies: libuv 1.53, LuaJIT 2.1.1788856981, tree-sitter 0.27, libvterm

## 📊 Progress

| Phase | Tasks | Status |
|-------|-------|--------|
| Bootstrap | TASK-001 to TASK-005 | ✅ Complete |
| Editor Core | TASK-006 to TASK-008 | ✅ Complete |
| Options & Autocmds | TASK-009 to TASK-012 | ✅ Complete |
| Infrastructure | TASK-INFRA-001 to TASK-INFRA-005 | ✅ Complete |

Run `./scripts/progress.sh` for the live pass/fail report.

## 📜 License

Apache 2.0 (retaining Neovim runtime NOTICE)
