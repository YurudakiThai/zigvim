# TASK-XXX: [Short Title]

**Priority:** P0/P1/P2  
**Depends on:** TASK-YYY, TASK-ZZZ  
**Estimated time:** N hours for agent  
**Test file:** `cases/TASK-XXX.lua`

---

## 🎯 Objective

[1-2 sentences: what this task implements and why it matters]

---

## 📋 Requirements

### Function Signatures (from real nvim)
```lua
-- Paste the exact signatures from real nvim
vim.api.nvim_xxx(...)
```

### Edge Cases (from test case)
1. [Case 1]
2. [Case 2]
3. [Case 3]

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-XXX --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "key": "value"
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Data Structure
- [Advice on internal representation]

### Index Translation
- [0-based vs 1-based, -1 semantics]

### Error Handling
- [When to raise Lua errors]

### Integration with Lua
- [How to expose to vim.api table]

---

## ✅ Acceptance Criteria

- [ ] `./scripts/verify.sh TASK-XXX` exits with code 0.
- [ ] Output matches real nvim exactly (JSON deep-equal).
- [ ] No crashes or memory leaks.
- [ ] Commit message: `feat(TASK-XXX): [short description]`

---

## 📚 References

- Neovim source: `src/nvim/api/xxx.c`
- Test file: `cases/TASK-XXX.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- [Pitfall 1]
- [Pitfall 2]

---

*Task created: YYYY-MM-DD*  
*Status: 🟡 Ready for implementation*
