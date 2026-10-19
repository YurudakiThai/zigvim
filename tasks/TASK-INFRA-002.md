# TASK-INFRA-002: Implement libuv event loop wrapper

## Status
**DONE**

## Goal
Create a working libuv-based event loop that supports:
- `vim.schedule(fn)` — queue callback for next event loop tick
- `vim.defer_fn(fn, timeout)` — schedule callback after delay
- `vim.wait(timeout, condition, interval)` — poll condition with timeout

## Requirements

### 1. Zig-side (src/platform/uv.zig)
- [x] `Loop` wrapper (init, deinit, run, stop, isAlive) — TASK-INFRA-001
- [ ] `Timer` wrapper (init, start, stop, close, data)
- [ ] `Async` wrapper (init, send, close)
- [ ] `Idle` wrapper (init, start, stop, close)

### 2. Lua-side bindings
- [ ] `vim.uv.new_timer()` — returns timer object with :start/:stop/:close
- [ ] `vim.schedule(fn)` — returns handle, enqueues callback
- [ ] `vim.defer_fn(fn, timeout)` — returns timer handle
- [ ] `vim.wait(timeout, condition, interval)` — returns result, timeout_reason

### 3. Event loop integration
- [ ] Main loop pumps event loop after script execution
- [ ] Scheduled callbacks run in FIFO order
- [ ] Timers fire at correct times
- [ ] Event loop exits when no active handles remain

## Test Cases

### Test 1: vim.schedule basic
```lua
local ran = false
vim.schedule(function() ran = true end)
-- After event loop: ran should be true
```

### Test 2: vim.defer_fn basic
```lua
local ran = false
vim.defer_fn(function() ran = true end, 50)
-- After event loop: ran should be true
```

### Test 3: vim.wait with condition
```lua
local counter = 0
local timer = vim.uv.new_timer()
timer:start(10, 10, function() counter = counter + 1 end)
local result = vim.wait(200, function() return counter >= 3 end, 20)
-- result should be true
timer:stop()
timer:close()
```

### Test 4: vim.wait timeout
```lua
local result, reason = vim.wait(50, function() return false end, 20)
-- result should be false, reason should be "timeout"
```

## Neovim Reference

```
vim.schedule({fn})                                    *vim.schedule()*
    Schedules {fn} to be invoked at the next event loop iteration.

vim.defer_fn({fn}, {timeout})                        *vim.defer_fn()*
    Defers calling {fn} until {timeout} ms passes.

vim.wait({time}, {condition}, {interval}, {fast_break}) *vim.wait()*
    Wait until {condition} returns truthy or {time} ms pass.
    Returns:
        true, nil       if condition returned truthy
        false, "timeout" if timeout expired
        false, "interrupted" if interrupted
```

## Architecture Decision

We use libuv timers directly instead of implementing our own timing logic:
- `vim.schedule(fn)` → create 0ms timer, close after callback
- `vim.defer_fn(fn, timeout)` → create timeout ms timer, close after callback  
- `vim.wait(timeout, condition, interval)` → create repeating interval timer, check condition in each tick, stop on true or timeout

This matches Neovim's actual implementation and gives us correct timing behavior across platforms.

## Files Modified
- `src/platform/uv.zig` — Timer, Async, Idle wrappers
- `src/main.zig` — Lua bindings, event loop integration
- `cases/TASK-INFRA-002.lua` — test cases

## Verification
```bash
./scripts/verify.sh TASK-INFRA-002
```

Expected output matches Neovim 0.12.6.
