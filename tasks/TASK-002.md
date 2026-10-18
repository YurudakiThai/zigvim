# TASK-002: Embed LuaJIT 2.1

**Priority:** P0 (critical for Lua compatibility)  
**Depends on:** TASK-001 (bootstrap)  
**Estimated time:** 1-2 hours for agent  
**Test file:** `cases/TASK-002.lua`

---

## 🎯 Objective

Embed LuaJIT 2.1.1788856981 (from Homebrew) into zigvim. The binary must:
- Initialize a LuaJIT state
- Run arbitrary Lua code
- Capture stdout from Lua's `print()` and `io.stdout:write()`
- Exit cleanly

---

## 📋 Requirements

### LuaJIT Integration
- Link against LuaJIT 2.1.1788856981 (brew install luajit)
- Use LuaJIT's C API (`lua.h`, `lauxlib.h`, `lualib.h`)
- Initialize state: `luaL_openlibs(L)`
- Run code: `luaL_dostring(L, code)`

### CLI Interface
```bash
zigvim --headless --clean -l <script.lua> -c "qa!"
```
- `-l` loads and executes the Lua script
- `-c "qa!"` tells zigvim to quit after execution
- stdout from Lua goes to zigvim's stdout

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-002 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "lua_version": "Lua 5.1",
  "jit_version": "LuaJIT 2.1.1788856981",
  "can_require": true,
  "math_pi": 3.141592653589793
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Linking LuaJIT
In `build.zig`:
```zig
const luajit = b.addSystemCommand(&.{"pkg-config", "--libs", "luajit"});
exe.linkSystemLibrary("luajit");
exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
```

### Basic Lua Execution
```zig
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

fn run_lua(code: []const u8) !void {
    var L = c.luaL_newstate();
    defer c.lua_close(L);
    c.luaL_openlibs(L);
    
    if (c.luaL_dostring(L, code.ptr) != 0) {
        const err = c.lua_tostring(L, -1);
        std.debug.print("Lua error: {s}\n", .{err});
        return error.LuaError;
    }
}
```

### Capturing stdout
Lua's `io.stdout` writes to C's stdout. Just ensure your Zig binary doesn't buffer stdout unexpectedly:
```zig
const stdout = std.io.getStdOut().writer();
try stdout.writeAll("output");
```

---

## ✅ Acceptance Criteria

- [ ] `zig build` links LuaJIT successfully
- [ ] `zigvim --headless -l script.lua -c "qa!"` runs Lua and exits
- [ ] `./scripts/verify.sh TASK-002` exits with code 0
- [ ] Commit message: `feat(TASK-002): embed LuaJIT 2.1 and run Lua scripts`

---

## 📚 References

- LuaJIT source: `/opt/homebrew/opt/luajit/include/`
- Lua 5.1 manual: https://www.lua.org/manual/5.1/
- Test file: `cases/TASK-002.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **LuaJIT vs Lua:** Must use LuaJIT 2.1, not Lua 5.4. LuaJIT has FFI, different behavior.
- **Stdout buffering:** Use `std.io.getStdOut().writer()` directly, not `std.debug.print`.
- **Error handling:** If `luaL_dostring` returns non-zero, extract error with `lua_tostring`.

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
