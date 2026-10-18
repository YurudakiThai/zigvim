# TASK-001: Bootstrap Repo & Build System

**Priority:** P0 (critical foundation)  
**Depends on:** None  
**Estimated time:** 30 minutes for agent  
**Test file:** `cases/TASK-001.lua`

---

## 🎯 Objective

Create the zigvim project structure with a working `build.zig` that produces a `zigvim` binary. The binary should:
- Print "zigvim v0.1.0" when run with `--version`
- Run a minimal Lua script passed as argument

---

## 📋 Requirements

### CLI Interface
```bash
zigvim --version
# Output: zigvim v0.1.0

zigvim --headless --clean -l <lua-script.lua> -c "qa!"
# Runs the Lua script and exits
```

### Build System
- `build.zig` that compiles Zig 0.17.0
- Output binary: `zig-out/bin/zigvim`
- No dependencies yet (just Zig stdlib)

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-001 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "version": "0.12.6",
  "can_run_lua": true,
  "lua_output": "hello from lua"
}
```

Your implementation must produce **exactly** this output (deep-equal JSON), but with `"version": "0.1.0"` instead.

---

## 🛠️ Implementation Hints

### Project Structure
```
zigvim/
├── build.zig
├── build.zig.zon
├── src/
│   └── main.zig
├── tasks/
├── cases/
└── scripts/
```

### Minimal main.zig
```zig
const std = @import("std");

pub fn main() !void {
    const args = std.process.argsAlloc(std.heap.page_allocator) catch return;
    defer std.process.argsFree(std.heap.page_allocator, args);
    
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("zigvim v0.1.0\n", .{});
            return;
        }
    }
    
    // TODO: implement -l flag to run Lua scripts
}
```

### Lua Script Execution
For this task, you don't need to actually run Lua yet. Just:
1. Parse `-l <script.lua>` from args
2. Print "hello from lua" (we'll implement real Lua in TASK-002)

---

## ✅ Acceptance Criteria

- [ ] `zig build` succeeds
- [ ] `./zig-out/bin/zigvim --version` prints "zigvim v0.1.0"
- [ ] `./scripts/verify.sh TASK-001` exits with code 0 (with mock Lua output)
- [ ] Commit message: `feat(TASK-001): bootstrap repo structure and build system`

---

## 📚 References

- Zig build system: https://ziglang.org/documentation/0.17.0/#Build-System
- Test file: `cases/TASK-001.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Zig version:** Must use Zig 0.17.0 (not 0.16 or 0.18). Check with `zig version`.
- **Build output:** Binary must be at `zig-out/bin/zigvim` (not `zig-out/zigvim`).
- **Exit code:** Always exit with 0 on success. Oracle checks exit code.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
