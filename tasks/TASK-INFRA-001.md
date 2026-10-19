# TASK-INFRA-001: Link libuv in build.zig (Cross-Platform)

**Status:** ✅ Complete  
**Phase:** 0 (Reset & Infrastructure)  
**Estimated Time:** 1-2 hours  
**Actual Time:** ~30 minutes  
**Dependencies:** RESET-001, RESET-002  
**Completed:** 2026-10-19

---

## 🎯 Objective

Link libuv to the zigvim build system with full cross-platform support (Linux, macOS, Windows). Remove hardcoded Homebrew paths and use Zig's build system to discover libuv automatically.

---

## 📋 Requirements

### Must Have
1. **Link libuv** using `linkSystemLibrary` in build.zig
2. **Cross-platform support**: Works on Linux (x86_64, arm64), macOS (x86_64, arm64), Windows (x86_64)
3. **Remove hardcoded paths**: No `/opt/homebrew/...` references in build.zig
4. **Basic libuv wrapper**: Create `src/platform/uv.zig` with minimal API wrapper
5. **Test compilation**: `zig build` succeeds on all target platforms
6. **Runtime check**: Call `uv_version_string()` from main.zig to verify linkage

### Should Have
1. **Build options**: Allow user to specify libuv path via `-Dlibuv-path=...`
2. **Error messages**: Clear error if libuv not found on system

### Nice to Have
1. **Static linking option**: `-Dlibuv-static=true` for static linking
2. **Vendored libuv**: Option to build libuv from source (future task)

---

## 🔧 Implementation Plan

### Step 1: Update build.zig
```zig
// Remove hardcoded paths
exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" }); // ❌ Remove

// Add libuv linking (cross-platform)
exe.root_module.linkSystemLibrary("uv", .{});

// For LuaJIT, use pkg-config or system library discovery
exe.root_module.linkSystemLibrary("luajit", .{});
```

### Step 2: Create src/platform/uv.zig
```zig
const std = @import("std");
const c = @import("c");

pub const Loop = struct {
    handle: c.uv_loop_t,

    pub fn init() !Loop {
        var loop: Loop = undefined;
        const result = c.uv_loop_init(&loop.handle);
        if (result != 0) return error.LoopInitFailed;
        return loop;
    }

    pub fn deinit(self: *Loop) void {
        _ = c.uv_loop_close(&self.handle);
    }

    pub fn run(self: *Loop, mode: c.uv_run_mode) !void {
        const result = c.uv_run(&self.handle, mode);
        if (result != 0) return error.LoopRunFailed;
    }
};

pub fn getVersionString() [*:0]const u8 {
    return c.uv_version_string();
}
```

### Step 3: Update src/lua_bindings.h
Add libuv headers:
```c
#include <uv.h>
```

### Step 4: Update main.zig
Add platform module import and test:
```zig
const uv = @import("platform/uv.zig");

// In main()
std.debug.print("libuv version: {s}\n", .{uv.getVersionString()});
```

---

## ✅ Acceptance Criteria

### Automated Tests
1. **Build test**: `zig build` succeeds without errors
2. **Version check**: Running `./zig-out/bin/zigvim --version` prints libuv version
3. **Cross-compile test** (if toolchain available):
   - `zig build -Dtarget=x86_64-linux-gnu` succeeds
   - `zig build -Dtarget=x86_64-macos` succeeds

### Manual Tests
```bash
# 1. Clean build
rm -rf zig-cache zig-out
zig build

# 2. Run version check
./zig-out/bin/zigvim --version
# Expected output:
# zigvim v0.1.0
# libuv version: 1.44.2 (or similar)

# 3. Run existing tests
./scripts/verify.sh all
# Expected: 12/12 tasks pass
```

---

## 🐛 Known Issues & Solutions

### Issue 1: libuv not found on system
**Error:** `error: unable to find system library 'uv'`

**Solution:**
- **Linux:** `sudo apt install libuv1-dev` (Ubuntu/Debian) or `sudo pacman -S libuv` (Arch)
- **macOS:** `brew install libuv`
- **Windows:** Install libuv via vcpkg or build from source

### Issue 2: LuaJIT not found
**Error:** `error: unable to find system library 'luajit'`

**Solution:**
- **Linux:** `sudo apt install libluajit-5.1-dev`
- **macOS:** `brew install luajit`
- **Windows:** Build LuaJIT from source or use pre-built binaries

### Issue 3: Hardcoded paths still present
**Symptom:** Build succeeds but only on developer's machine

**Solution:** Search build.zig for `/opt/homebrew` and remove all references

---

## 📊 Success Metrics

- ✅ `zig build` succeeds on native platform
- ✅ `./zig-out/bin/zigvim --version` prints both zigvim and libuv versions
- ✅ All 12 existing conformance tests still pass
- ✅ No hardcoded paths in build.zig
- ✅ Cross-compilation works (if toolchain available)

---

## 🔗 Related Tasks

- **INFRA-002:** Implement libuv event loop wrapper (builds on this task)
- **INFRA-008:** Implement platform/terminal.zig (Unix) - will use libuv for I/O
- **INFRA-009:** Implement platform/terminal.zig (Windows) - will use libuv for I/O
- **INFRA-010:** Implement platform/paths.zig - may use libuv for path operations

---

## 📝 Notes

### Why libuv?
libuv is the same library Neovim uses for its event loop. It provides:
- Cross-platform event loop (epoll/kqueue/IOCP)
- File I/O
- Process spawning
- TCP/UDP/Unix sockets/Named pipes
- Signals, timers, threads
- Thread pool

Using libuv from day one ensures we can implement Neovim-compatible features without rewriting platform-specific code later.

### Alternative Approaches Considered
1. **Use std.event.Loop (Zig native):** Not stable enough, lacks Windows support
2. **Write platform-specific code manually:** Too much work, error-prone
3. **Use another event loop library:** libuv is the industry standard (Node.js, Neovim, etc.)

**Decision:** Use libuv with Zig bindings via C interop

---

## 🚀 Getting Started

```bash
# 1. Install libuv (if not already installed)
# macOS
brew install libuv

# Linux (Ubuntu/Debian)
sudo apt install libuv1-dev

# Linux (Arch)
sudo pacman -S libuv

# 2. Build
cd ~/zigvim
zig build

# 3. Verify
./zig-out/bin/zigvim --version
# Should print: zigvim v0.1.0, libuv 1.44.2
```

---

**Last Updated:** 2026-10-19  
**Assigned to:** AI Agent  
**Priority:** High (blocks all future event loop work)
