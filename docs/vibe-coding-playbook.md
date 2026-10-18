# Vibe Coding Playbook: zigvim Differential Test Harness

> **A self-verifying development loop for building Neovim in Zig with AI coding agents.**  
> Real nvim is the oracle. Every commit is verified. No human judgment needed.

---

## 🎯 Why This Fits Vibe Coding Perfectly

**Vibe coding** = you describe what you want, an AI agent builds it, you verify it works.

The problem: how do you verify an AI built the right thing without reading the code yourself?

**The solution:** use real nvim as the ground truth. The agent writes zigvim code, runs a Lua test, and compares the output to real nvim. If they match, it's correct. If they differ, the agent fixes it.

This is **perfect for vibe coding** because:
- ✅ **No manual review needed** — the oracle is objective truth
- ✅ **Immediate feedback** — `./scripts/verify.sh TASK-XXX` tells you pass/fail instantly
- ✅ **No hallucinated specs** — real nvim IS the spec, the agent can't invent fake behavior
- ✅ **Small, atomic tasks** — each task is one prompt, one commit, one verify
- ✅ **Progress is measurable** — count passing tasks vs failing tasks

---

## 🚀 Quick Start (5 Minutes)

### 1. Clone This Package
```bash
cp -r ~/zigvim-conformance-harness/vibe-coding ~/zigvim
cd ~/zigvim
```

### 2. Install Dependencies
```bash
# Already installed on your system:
# - Zig 0.17.0 (/opt/homebrew/bin/zig)
# - Neovim 0.12.6 (/opt/homebrew/bin/nvim)
# - Python 3.13.0 (stdlib only — no pip install needed)

# Verify they work:
zig version
nvim --version | head -1
python3 --version
```

### 3. Run the Oracle (Sanity Check)
```bash
cd ~/zigvim
./scripts/verify.sh TASK-006 --nvim-only --show-output
```

**Expected output:**
```
Running test: TASK-006.lua
  nvim: /opt/homebrew/bin/nvim

NVIM OUTPUT:
{
  "after_delete": ["replaced"],
  "after_insert": ["alpha", "inserted", "β-greek", "third line"],
  "after_replace": ["replaced", "β-greek", "third line"],
  "buffer_is_valid": true,
  "line_count": 1,
  "lines": ["alpha", "β-greek", "third line"]
}
PASS (nvim-only mode)
```

If you see this, the oracle works. You're ready to vibe code.

### 4. Start a Vibe Coding Session
```bash
# Tell your AI agent (Claude, Cursor, Codex, etc.):
# "Read AGENTS.md, then start with TASK-006. Run ./scripts/verify.sh TASK-006 --nvim-only to see the expected output, then implement it in Zig. Commit when it passes."
```

That's it. The agent will:
1. Read the task card
2. See the expected output from real nvim
3. Implement the feature
4. Run `./scripts/verify.sh TASK-006`
5. Iterate until it passes
6. Commit

---

## 📦 What's in This Package

```
~/zigvim/
├── AGENTS.md                          ← Copy to project root (or .cursorrules/CLAUDE.md)
├── vibe-coding-playbook.md            ← This file
├── scripts/
│   ├── oracle.py                      ← Core oracle (stdlib-only Python)
│   ├── verify.sh                      ← Single-command gate
│   └── progress.sh                    ← Show pass/fail summary
├── tasks/
│   ├── TASK-001-bootstrap.md          ← Task cards (prioritized)
│   ├── TASK-002-luajit-embed.md
│   ├── TASK-006-buf-set-lines.md
│   └── TASK-TEMPLATE.md               ← Template for new tasks
├── cases/
│   ├── TASK-006.lua                   ← Lua test cases (runnable NOW)
│   └── ...
├── specs/
│   └── api-surface.md                 ← Machine-readable API contract
└── session/
    └── CURRENT.md                     ← Agent handoff state
```

---

## 🧭 The Vibe Coding Loop

### Step 1: Pick a Task
```bash
ls tasks/TASK-*.md
# Read the next task (e.g., TASK-006)
```

### Step 2: See the Expected Output
```bash
./scripts/verify.sh TASK-006 --nvim-only --show-output
```

### Step 3: Implement in Zig
The agent writes code, builds, and tests:
```bash
zig build
./scripts/verify.sh TASK-006
```

### Step 4: Iterate Until It Passes
If it fails, the agent sees the diff and fixes it:
```
FAIL: output differs

============================================================
NVIM (oracle):
{
  "lines": ["alpha", "β-greek", "third line"]
}

ZIGVIM:
{
  "lines": ["alpha", "beta-greek", "third line"]  ← wrong!
}
============================================================
```

### Step 5: Commit
```bash
git add -A
git commit -m "feat(TASK-006): implement nvim_buf_set_lines/get_lines"
```

### Step 6: Update Session State
Edit `session/CURRENT.md`:
```markdown
## Last Session: 2026-01-18
**Completed tasks:**
- TASK-006 (nvim_buf_set_lines): ✅
```

---

## 📋 Task Queue (Prioritized)

### Phase 0: Bootstrap (Week 1)
| Task | Description | Status |
|------|-------------|--------|
| TASK-001 | Create repo structure, build.zig skeleton | 🟡 Ready |
| TASK-002 | Embed LuaJIT 2.1.1788856981 | 🟡 Ready |
| TASK-003 | Copy `$VIMRUNTIME/lua` to zigvim | 🟡 Ready |

### Phase 1: Editor Core (Month 1-2)
| Task | Description | Status |
|------|-------------|--------|
| TASK-004 | Minimal oracle (stdlib-only Python) | ✅ Done |
| TASK-005 | Diff engine (deep-equal JSON) | ✅ Done |
| TASK-006 | `nvim_buf_set_lines` / `nvim_buf_get_lines` | 🟡 Ready |
| TASK-007 | `nvim_buf_is_valid` / `nvim_buf_line_count` | 🟡 Ready |
| TASK-008 | `nvim_get_current_buf` / `nvim_set_current_buf` | 🟡 Ready |

### Phase 2: Options & Autocmds (Month 3-4)
| Task | Description | Status |
|------|-------------|--------|
| TASK-009 | `nvim_get_option_value` / `nvim_set_option_value` | 🟡 Ready |
| TASK-010 | `vim.schedule` / `vim.defer_fn` (event loop) | 🟡 Ready |
| TASK-011 | `nvim_create_autocmd` / `nvim_exec_autocmds` | 🟡 Ready |

### Phase 3: UI & RPC (Month 5-6)
| Task | Description | Status |
|------|-------------|--------|
| TASK-012 | `nvim_ui_attach` (remote UI protocol) | 🟡 Ready |
| TASK-013 | `nvim_input` / `nvim_feedkeys` | 🟡 Ready |
| TASK-014 | TUI rendering (libvterm) | 🟡 Ready |

---

## 🛠️ How to Write New Tasks

### Step 1: Create the Task Card
```bash
cp tasks/TASK-TEMPLATE.md tasks/TASK-015.md
```

Edit `TASK-015.md`:
- Fill in the objective, requirements, edge cases
- Run `nvim --headless -c 'lua print(vim.inspect(vim.api.nvim_xxx))' -c 'qa!'` to discover signatures
- Add to `specs/api-surface.md`

### Step 2: Write the Test Case
```bash
cat > cases/TASK-015.lua <<'LUAEOF'
-- TASK-015: your test here
local out = {}
-- Call the API
out.result = vim.api.nvim_xxx(...)
io.stdout:write(vim.json.encode(out) .. "\n")
LUAEOF
```

### Step 3: Verify the Oracle Works
```bash
./scripts/verify.sh TASK-015 --nvim-only --show-output
```

If this passes, the test case is valid. Now the agent can implement it.

---

## 📊 Progress Tracking

### Check Overall Progress
```bash
./scripts/progress.sh
```

**Example output:**
```
=== zigvim conformance progress ===
Total tasks: 14
Pass: 3
Fail: 0
Not started: 11

=== Task list ===
  ✅ TASK-001 (bootstrap)
  ✅ TASK-002 (luajit-embed)
  ✅ TASK-003 (runtime-copy)
  🟡 TASK-006 (buf-set-lines)
  🟡 TASK-007 (buf-is-valid)
  ...
```

### Update After Each Session
Edit `session/CURRENT.md`:
```markdown
## Last Session: 2026-01-18
**Completed tasks:**
- TASK-006 (nvim_buf_set_lines): ✅
- TASK-007 (nvim_buf_is_valid): ✅

**Next task:**
- TASK-008 (nvim_get_current_buf)

**Blockers:**
- None

**Notes:**
- Discovered edge case with strict_indexing=false
```

---

## 🚫 Anti-Patterns (What NOT to Do)

### ❌ Don't Skip Verification
If you can't run `./scripts/verify.sh TASK-XXX`, you haven't finished the task.

### ❌ Don't Modify the Oracle
`scripts/oracle.py` is sacred. If tests fail, fix the implementation, not the oracle.

### ❌ Don't Combine Tasks
One task = one commit = one verify. Combining tasks makes it impossible to know which one failed.

### ❌ Don't Guess APIs
If `specs/api-surface.md` is missing a function, run `nvim --headless -c 'lua print(vim.inspect(vim.api.nvim_xxx))' -c 'qa!'` to discover it. Never hallucinate signatures.

### ❌ Don't Over-Engineer
Implement the minimum to pass the test. Optimize later.

---

## 🆘 When the Agent Gets Stuck

### Symptom: "I don't know how to implement this"
**Solution:** Point the agent to Neovim source:
```bash
# Show the agent the real implementation
nvim --headless -c 'edit /path/to/neovim/src/nvim/api/buffer.c' -c 'qa!'
```

### Symptom: "The test fails but I don't know why"
**Solution:** Show the diff:
```bash
./scripts/verify.sh TASK-006
```

The oracle prints both outputs side-by-side. The agent can see exactly what's wrong.

### Symptom: "I'm making progress but it's slow"
**Solution:** Break the task into smaller pieces:
```bash
# Instead of "implement nvim_buf_set_lines", do:
# 1. Implement buffer data structure
# 2. Implement line count
# 3. Implement set_lines (replace entire buffer)
# 4. Implement set_lines (insert in middle)
# 5. Implement set_lines (delete range)
```

---

## 🎓 Advanced: Writing a Progress Dashboard

### Automated Progress Script
```bash
#!/bin/bash
# scripts/progress.sh

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

echo "=== zigvim conformance progress ==="
total=$(ls "$ROOT/cases"/TASK-*.lua | wc -l)
pass=0
fail=0

for f in "$ROOT/cases"/TASK-*.lua; do
  name=$(basename "$f" .lua)
  if python3 "$DIR/oracle.py" --test "$f" --nvim-only 2>/dev/null | grep -q "PASS"; then
    ((pass++))
    echo "  ✅ $name"
  else
    ((fail++))
    echo "  ❌ $name"
  fi
done

echo ""
echo "Total: $total | Pass: $pass | Fail: $fail"
```

### Visualize Progress Over Time
```bash
# Log progress daily
./scripts/progress.sh >> progress-history.jsonl

# Plot with Python
python3 -c "
import json, sys
for line in sys.stdin:
    data = json.loads(line)
    print(f'{data[\"date\"]}: {data[\"pass\"]}/{data[\"total\"]}')
" < progress-history.jsonl
```

---

## 🎉 Success Metrics

### Tier 2: Editor Core (1.5 years)
- ✅ All `vim.api.nvim_buf_*` functions (37 funcs)
- ✅ All `vim.api.nvim_win_*` functions (24 funcs)
- ✅ All `vim.api.nvim_tabpage_*` functions (8 funcs)
- ✅ `vim.o` / `vim.opt` (374 options)
- ✅ Plugins: lualine, bufferline, gitsigns, oil, conform

**Progress check:**
```bash
./scripts/verify.sh all | grep -E "(PASS|FAIL)" | wc -l
# Should be 181 (all vim.api functions)
```

### Tier 3: Full Parity (2.5 years)
- ✅ Treesitter integration
- ✅ LSP client (`vim.lsp`)
- ✅ Diagnostic engine
- ✅ Completion framework (blink.cmp, nvim-cmp)
- ✅ All 55 plugins in your corpus

**Progress check:**
```bash
# Test a plugin
./scripts/verify.sh PLUGIN-lualine
./scripts/verify.sh PLUGIN-gitsigns
```

---

## 📚 References

- **Differential Test Harness (original report):** `~/zigvim-conformance-harness/differential-test-harness.md`
- **Neovim source:** https://github.com/neovim/neovim
- **Zig language:** https://ziglang.org
- **LuaJIT:** https://luajit.org

---

## 🤝 Contributing

To add new tasks:
1. Fork this playbook
2. Add `tasks/TASK-XXX.md` and `cases/TASK-XXX.lua`
3. Submit a PR with proof that `./scripts/verify.sh TASK-XXX --nvim-only` works

---

*Last updated: 2026-01-18*  
*Author: Vibe Coding Community*
