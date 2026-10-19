# TASK-RESET-001: Git Hygiene & Clean Slate

**Status:** ✅ Complete  
**Priority:** Critical  
**Platform:** All  
**Estimated Time:** 30 minutes

---

## 🎯 Objective

Clean up the repository to prepare for the new Neovim-compatible architecture. This includes:
1. Commit uncommitted changes
2. Remove test artifacts
3. Archive old documentation
4. Remove Neovim runtime from git tracking
5. Create infrastructure for the new plan

---

## ✅ Acceptance Criteria

- [ ] All uncommitted changes are committed
- [ ] Test artifacts (`test_vim.txt`, `zigvim`, `nvim.log`) are removed
- [ ] Old docs archived in `docs/archive/2026-10-18-tui-phase/`
- [ ] Old session files archived in `session/archive/2026-10-18/`
- [ ] `runtime/lua/` removed from git tracking (still exists on disk)
- [ ] `.gitignore` updated to exclude build artifacts and runtime
- [ ] `scripts/fetch-runtime.sh` created to download Neovim runtime
- [ ] New plan document created: `docs/NEOVIM-COMPAT-PLAN.md`
- [ ] Directory structure created: `src/platform/`, `.github/workflows/`

---

## 📋 Steps

1. **Write proper .gitignore**
   - Exclude build outputs: `zig-out/`, `zig-cache/`, `zigvim`, `*.exe`
   - Exclude OS files: `.DS_Store`, `Thumbs.db`
   - Exclude test artifacts: `test_*.txt`, `*.log`
   - Exclude runtime: `runtime/lua/`

2. **Commit TUI work**
   - Stage all modified files: `git add -A`
   - Commit with message: "chore: complete TUI phase and update .gitignore"

3. **Archive old docs**
   - Move `docs/QUICK-REFERENCE.md` → `docs/archive/2026-10-18-tui-phase/`
   - Move `docs/TUI-FIXES.md` → `docs/archive/2026-10-18-tui-phase/`
   - Move `docs/tui-editor-implementation-plan.md` → `docs/archive/2026-10-18-tui-phase/`

4. **Archive old session files**
   - Move `session/CURRENT.md` → `session/archive/2026-10-18/`
   - Move `session/history.csv` → `session/archive/2026-10-18/`

5. **Remove runtime from git tracking**
   - Create `scripts/fetch-runtime.sh` to download Neovim runtime
   - Run `git rm -r --cached runtime/lua` to untrack
   - Runtime still exists on disk but won't be committed

6. **Create new infrastructure**
   - Create `docs/NEOVIM-COMPAT-PLAN.md`
   - Create `src/platform/` directory
   - Create `.github/workflows/` directory

---

## 🧪 Verification

```bash
# Check git status is clean
git status --short
# Should show only staged changes (new plan doc, directories)

# Verify runtime is not tracked
git ls-files runtime/lua
# Should return nothing

# Verify fetch script exists
ls -l scripts/fetch-runtime.sh

# Verify plan doc exists
ls -l docs/NEOVIM-COMPAT-PLAN.md
```

---

## 📝 Notes

- This task is about **cleanup and preparation**, not new features
- The old TUI work is legitimate learning but architecturally wrong for the new plan
- The runtime is 3.3MB of Neovim's code — should be fetched, not committed
- After this task, the repo is ready for RESET-002 (remove TUI from main.zig)
