# TASK-011: Event Loop (vim.schedule, vim.defer_fn, vim.wait)

**Priority:** P0 (critical for async operations)  
**Depends on:** TASK-010 (variables)  
**Estimated time:** 4-6 hours for agent  
**Test file:** `cases/TASK-011.lua`

---

## 🎯 Objective

Implement async primitives using libuv:
- `vim.schedule(fn)` — schedule function to run on next event loop iteration
- `vim.defer_fn(fn, timeout)` — run function after timeout (ms)
- `vim.wait(timeout, condition, interval)` — wait for condition or timeout

These are needed for LSP, treesitter, and all async plugins.

---

## 📋 Requirements

### Function Signatures
```lua
-- Schedule function on main thread
vim.schedule(function()
  -- runs on next event loop iteration
end)

-- Defer function execution
vim.defer_fn(function()
  -- runs after timeout ms
end, 100)

-- Wait for condition
local ok = vim.wait(1000, function()
  return some_condition
end, 200)  -- check every 200ms
-- Returns: true if condition met, false if timeout
```

### Behavior
- **vim.schedule:** Runs on next loop iteration (not immediately)
- **vim.defer_fn:** Uses libuv timers
- **vim.wait:** Polls condition at interval, returns false on timeout

---

## 🔍 Verification

Run this to see the expected output from real nvim:
```bash
./scripts/verify.sh TASK-011 --nvim-only --show-output
```

Expected output (from real nvim 0.12.6):
```json
{
  "schedule_executed": true,
  "defer_executed": true,
  "wait_true": true,
  "wait_false": false
}
```

Your implementation must produce **exactly** this output (deep-equal JSON).

---

## 🛠️ Implementation Hints

### Link libuv
In `build.zig`:
```zig
exe.linkSystemLibrary("uv");
```

### Event Loop
```zig
var loop: c.uv_loop_t = undefined;
c.uv_loop_init(&loop);

fn run_loop() void {
    while (c.uv_run(&loop, c.UV_RUN_DEFAULT) != 0) {}
}
```

### vim.schedule
```zig
var scheduled_callbacks = ArrayList(fn () void).init(allocator);

fn vim_schedule(L: *c.lua_State) c_int {
    // Store Lua callback reference
    // Add to scheduled_callbacks
    return 0;
}
```

### vim.defer_fn (using libuv timer)
```zig
fn vim_defer_fn(L: *c.lua_State) c_int {
    const timeout = c.lua_tointeger(L, 2);
    
    var timer: *c.uv_timer_t = allocator.create(c.uv_timer_t) catch return 0;
    c.uv_timer_init(&loop, timer);
    
    // Store callback reference
    c.uv_timer_start(timer, on_timer, timeout, 0);
    
    return 0;
}
```

---

## ✅ Acceptance Criteria

- [ ] `vim.schedule(fn)` executes function on next loop iteration
- [ ] `vim.defer_fn(fn, 100)` executes after ~100ms
- [ ] `vim.wait(1000, cond)` returns true if condition met
- [ ] `./scripts/verify.sh TASK-011` exits with code 0
- [ ] Commit message: `feat(TASK-011): implement event loop (schedule/defer/wait)`

---

## 📚 References

- Neovim source: `src/nvim/event/loop.c` (event loop)
- libuv docs: https://docs.libuv.org/
- Test file: `cases/TASK-011.lua`
- Oracle: `scripts/oracle.py`

---

## 🆘 Common Pitfalls

- **Event loop blocking:** Don't block the main thread. Use libuv async I/O.
- **Timer cleanup:** Must stop and close timers after they fire.
- **Lua callback lifetime:** Keep Lua reference alive until callback executes.
- **vim.wait polling:** Check condition at interval, not continuously (CPU waste).

---

*Task created: 2026-10-18*  
*Status: 🟡 Ready for implementation*
