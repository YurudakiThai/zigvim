# AGENTS.md — Vibe Coding Protocol for zigvim

> **A self-verifying development workflow for building Neovim-compatible editor in Zig**

---

## 🎯 Mission

Build a Neovim-compatible editor in Zig that:
- Works on Windows, macOS, and Linux
- Passes differential tests against Neovim 0.12.6
- Can run LazyVim / AstroNvim distributions
- Connects to external UI clients via msgpack-RPC

---

## 🧭 Operating Principles

### 1. **Oracle is Law**
Neovim 0.12.6 is the source of truth. If zigvim's output doesn't match Neovim's output, zigvim is wrong.

### 2. **One Task, One Commit**
Each `tasks/TASK-*.md` is one atomic unit of work. Do NOT combine tasks. Do NOT skip verification. After completing a task, run `./scripts/verify.sh TASK-XXX` and commit only if it passes.

### 3. **No Hallucinated APIs**
If you're unsure about a Neovim API, inspect it:
```bash
nvim --headless -c 'lua print(vim.inspect(vim.api.nvim_xxx))' -c 'qa!'
```
Don't guess. Don't assume. Verify.

### 4. **Test First, Code Second**
1. Read `tasks/TASK-XXX.md`
2. Run `./scripts/verify.sh TASK-XXX --nvim-only --show-output` to see expected behavior
3. Implement the feature
4. Run `./scripts/verify.sh TASK-XXX` to verify
5. Commit if it passes

### 5. **Small Commits, Clear Messages**
- Task ≤ 500 lines of code
- Commit message format: `feat(TASK-XXX): short description`
- One commit per task

---

## 🔧 Workflow

### Starting a New Task
1. Read `tasks/TASK-XXX.md` for context, requirements, and acceptance criteria
2. Run `./scripts/verify.sh TASK-XXX --nvim-only --show-output` to see the expected output
3. Implement the feature in Zig (or C, or wherever appropriate)
4. Build: `zig build`
5. Test: `./scripts/verify.sh TASK-XXX`
6. If it passes, commit. If it fails, iterate.

### When Stuck
- **Don't guess.** Run `nvim --headless -c 'lua print(vim.inspect(vim.api.nvim_xxx))' -c 'qa!'` to inspect the real API
- **Don't over-engineer.** Implement the minimum to pass the test
- **Don't skip tests.** If a test fails, that's the bug you need to fix

### Updating Specs
- If you discover new API behavior not in `specs/api-surface.md`, add it
- Specs are machine-readable (YAML/JSON). Keep them accurate

---

## 🌍 Cross-Platform Requirements

zigvim must work on:
- **Linux:** x86_64, arm64
- **macOS:** Intel (x86_64), Apple Silicon (arm64)
- **Windows:** Windows 10+, x86_64

All platform-specific code lives in `src/platform/`. Use libuv for cross-platform abstractions.

---

## 📊 Progress Tracking

Run `./scripts/progress.sh` to see:
- Total tasks
- Passed tasks
- Failed tasks
- % completion

---

## 📖 Documentation

- **AGENTS.md** — this file (protocol for AI coding agents)
- **docs/NEOVIM-COMPAT-PLAN.md** — architecture and roadmap
- **docs/differential-test-harness.md** — test infrastructure design
- **docs/vibe-coding-playbook.md** — workflow guide
- **tasks/** — task cards (RESET-001 through PHASE5-XXX)
- **specs/api-surface.md** — machine-readable API contract

---

## 🚀 Quick Start

```bash
# Clone repo
git clone https://github.com/yourusername/zigvim
cd zigvim

# Fetch Neovim runtime
./scripts/fetch-runtime.sh

# Build
zig build

# Run all tests
./scripts/verify.sh all

# See progress
./scripts/progress.sh
```

---

## 📝 Notes

- This protocol supersedes all previous workflows
- The old TUI-focused plan is archived in `docs/archive/2026-10-18-tui-phase/`
- The new architecture follows Neovim's actual design (kernel + external UI)

---

**Last Updated:** 2026-10-19  
**Maintainer:** zigvim team
