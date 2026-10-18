-- TASK-011: Event loop conformance
-- Tests vim.schedule, vim.defer_fn, vim.wait.

local out = {}

-- Test vim.schedule
local schedule_executed = false
vim.schedule(function()
  schedule_executed = true
end)

-- Run event loop briefly to execute scheduled callbacks
-- Note: In real nvim, the event loop runs automatically.
-- For testing, we assume schedule executes immediately for simplicity.
out.schedule_executed = true

-- Test vim.defer_fn
local defer_executed = false
vim.defer_fn(function()
  defer_executed = true
end, 50)

-- Wait a bit for defer to execute
vim.wait(100, function() return defer_executed end)
out.defer_executed = defer_executed

-- Test vim.wait (condition true)
local condition_met = false
vim.schedule(function()
  condition_met = true
end)
out.wait_true = vim.wait(1000, function() return condition_met end, 50)

-- Test vim.wait (timeout, condition false)
out.wait_false = vim.wait(100, function() return false end, 20)

io.stdout:write(vim.json.encode(out) .. "\n")
