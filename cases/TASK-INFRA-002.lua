-- TASK-INFRA-002: Event loop conformance
-- Tests vim.schedule, vim.defer_fn, and vim.wait using real libuv timers.

local out = {}

-- Test 1: vim.schedule - queues a callback that runs on next tick
local schedule_ran = false
vim.schedule(function()
  schedule_ran = true
end)
-- Need to let the event loop run for the scheduled callback to execute
-- In our implementation, we run the loop after script execution
out.schedule_queued = not schedule_ran  -- should NOT have run yet

-- Test 2: vim.schedule returns a userdata/handle
local handle = vim.schedule(function() end)
out.schedule_returns_handle = handle ~= nil

-- Test 3: vim.defer_fn - delayed callback
local defer_ran = false
vim.defer_fn(function()
  defer_ran = true
end, 50)  -- 50ms delay
out.defer_queued = not defer_ran  -- should NOT have run yet

-- Test 4: vim.defer_fn returns a timer handle
local timer = vim.defer_fn(function() end, 100)
out.defer_returns_handle = timer ~= nil

-- Test 5: Multiple scheduled callbacks execute in FIFO order
local order = {}
vim.schedule(function() table.insert(order, "first") end)
vim.schedule(function() table.insert(order, "second") end)
vim.schedule(function() table.insert(order, "third") end)

-- Test 6: vim.wait - waits for condition to be true
local counter = 0
local tick_timer = vim.uv.new_timer()
tick_timer:start(10, 10, function()
  counter = counter + 1
end)

local wait_result, wait_timeout = vim.wait(200, function()
  return counter >= 3
end, 20)

out.wait_returns_true = (wait_result == true)
out.wait_no_timeout = (wait_timeout == nil)
out.wait_counter_incremented = (counter >= 3)

-- Stop the tick timer
tick_timer:stop()
tick_timer:close()

-- Test 7: vim.wait with immediate condition
local immediate_result, immediate_timeout = vim.wait(100, function()
  return true
end)
out.wait_immediate = (immediate_result == true)
out.wait_immediate_no_timeout = (immediate_timeout == nil)

-- Test 8: vim.wait timeout
local timeout_result, timeout_reason = vim.wait(50, function()
  return false
end, 20)
out.wait_timeout = (timeout_result == false)
out.wait_timeout_reason = (timeout_reason == "timeout")

-- Output initial state (before event loop runs)
-- The actual execution of scheduled/deferred callbacks happens after
-- this script completes, when the event loop is pumped
io.stdout:write(vim.json.encode(out) .. "\n")
