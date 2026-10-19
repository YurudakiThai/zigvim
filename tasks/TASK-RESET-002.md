# TASK-RESET-002: Remove TUI from main.zig

**Status:** ✅ Complete  
**Priority:** Critical  
**Platform:** All  
**Estimated Time:** 1 hour

---

## 🎯 Objective

Remove the in-process TUI implementation from `main.zig` and replace it with a minimal RPC server stub. The TUI will be reimplemented later as a separate program that connects to the core via RPC.

---

## ✅ Acceptance Criteria

- [ ] `main.zig` no longer contains TUI code (editor.zig, render.zig, terminal.zig not imported)
- [ ] `main.zig` implements minimal RPC server that listens on stdin/stdout
- [ ] `zig build` succeeds
- [ ] `./zig-out/bin/zigvim --version` still works
- [ ] `./zig-out/bin/zigvim --embed` starts RPC server (waits for input)
- [ ] Old TUI files moved to `src/archive/tui-phase-1/`

---

## 📋 Steps

1. **Create archive directory**
   ```bash
   mkdir -p src/archive/tui-phase-1
   ```

2. **Move TUI files to archive**
   ```bash
   mv src/editor.zig src/archive/tui-phase-1/
   mv src/render.zig src/archive/tui-phase-1/
   mv src/terminal.zig src/archive/tui-phase-1/
   ```

3. **Rewrite main.zig**
   - Remove imports of editor, render, terminal
   - Add minimal RPC server that:
     - Reads msgpack requests from stdin
     - Writes msgpack responses to stdout
     - Handles `nvim_get_api_info` (return empty API metadata)
   - Keep argument parsing for `--version` and `--embed`

4. **Test**
   ```bash
   zig build
   ./zig-out/bin/zigvim --version  # Should print version
   ./zig-out/bin/zigvim --embed    # Should wait for input (Ctrl+C to exit)
   ```

5. **Commit**
   ```bash
   git add -A
   git commit -m "refactor(RESET-002): remove TUI, add RPC server stub"
   ```

---

## 🧪 Verification

```bash
# Check main.zig is small
wc -l src/main.zig
# Should be < 100 lines

# Check TUI files are archived
ls src/archive/tui-phase-1/
# Should show editor.zig, render.zig, terminal.zig

# Check build works
zig build

# Check --version works
./zig-out/bin/zigvim --version

# Check --embed works (should wait for input)
timeout 2 ./zig-out/bin/zigvim --embed
# Should timeout (waiting for RPC)
```

---

## 📝 Notes

- This is a **refactor**, not a feature addition
- The goal is to make main.zig minimal and focused on RPC
- Later tasks will add proper msgpack encoding/decoding and API handlers
- The archived TUI code can be reused for the standalone TUI client (Phase 2)
