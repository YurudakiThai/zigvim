# AGENTS.md — Vibe Coding Protocol for zigvim

> This defines how AI coding agents operate in this repository.

---

## 🎯 Mission

Build `zigvim`: a Neovim-compatible editor written in Zig, with full Lua plugin compatibility. The differential test harness (real nvim as oracle) is the **only source of truth**.

---

## 🧭 Operating Principles

### 1. **Oracle is Law**
- Real nvim (`/opt/homebrew/bin/nvim`) is the ground truth.
- Every implementation MUST match nvim's output exactly (JSON deep-equal).
- If your code differs from nvim, it's wrong. Fix it.

### 2. **One Task, One Commit**
- Each `tasks/TASK-*.md` is one atomic unit of work.
- Do NOT combine tasks. Do NOT skip verification.
- After completing a task, run `./scripts/verify.sh TASK-XXX` and commit only if it passes.

### 3. **No Hallucinated APIs**
- Before implementing any `vim.api.nvim_*` function, read the spec in `specs/api-surface.md`.
- If the spec is missing, run `nvim --headless -c 'lua print(vim.inspect(vim.api))' -c 'qa!'` to discover the signature, then add it to the spec.
- Never guess signatures. Always verify against real nvim.

### 4. **Test First, Code Second**
- Every task has a `cases/TASK-XXX.lua` test file.
- Run `./scripts/verify.sh TASK-XXX --nvim-only` to see the expected output BEFORE coding.
- Implement until `./scripts/verify.sh TASK-XXX` passes (exit code 0).

### 5. **Small Commits, Clear Messages**
- Commit message format: `feat(TASK-XXX): short description`
- Example: `feat(TASK-006): implement nvim_buf_set_lines/get_lines`
- Each commit = one verified task.

---

## 🔧 Workflow

### Starting a New Task
1. Read `tasks/TASK-XXX.md` for context, requirements, and acceptance criteria.
2. Run `./scripts/verify.sh TASK-XXX --nvim-only --show-output` to see the expected output.
3. Implement the feature in Zig (or C, or wherever appropriate).
4. Build: `zig build`
5. Test: `./scripts/verify.sh TASK-XXX`
6. If it passes, commit. If it fails, iterate.

### When Stuck
- **Don't guess.** Run `nvim --headless -c 'lua print(vim.inspect(vim.api.nvim_xxx))' -c 'qa!'` to inspect the real API.
- **Don't over-engineer.** Implement the minimum to pass the test.
- **Don't skip tests.** If a test fails, that's the bug you need to fix.

### Updating Specs
- If you discover new API behavior not in `specs/api-surface.md`, add it.
- Specs are machine-readable (YAML/JSON). Keep them accurate.

---

## 📊 Progress Tracking

After each session, update `session/CURRENT.md`:
```markdown
## Session: 2026-10-18
- Completed: TASK-006 (nvim_buf_set_lines)
- Next: TASK-007 (nvim_buf_get_lines)
- Blockers: none
- Notes: discovered edge case with -1 end index
```

Run `./scripts/progress.sh` to see pass/fail summary across all tasks.

---

## 🚫 Forbidden Actions

- ❌ Do NOT modify `scripts/oracle.py` to make tests pass. The oracle is sacred.
- ❌ Do NOT skip `./scripts/verify.sh`. If you can't verify it, you haven't finished.
- ❌ Do NOT implement features without a corresponding `cases/TASK-XXX.lua` test.
- ❌ Do NOT merge tasks. One task = one commit = one verify.

---

## ✅ Definition of Done

A task is "done" when:
1. `./scripts/verify.sh TASK-XXX` exits with code 0.
2. The commit message follows the format `feat(TASK-XXX): ...`.
3. `session/CURRENT.md` is updated with progress.
4. No regressions in `./scripts/verify.sh all`.

---

## 🆘 Emergency Contacts

If you're blocked:
- Check `session/CURRENT.md` for recent blockers.
- Run `./scripts/verify.sh all` to see which tasks are failing.
- Read `docs/differential-test-harness.md` for architecture details.
- When in doubt, **ask the human**. Never silently guess.

---

*Last updated: 2026-10-18*
