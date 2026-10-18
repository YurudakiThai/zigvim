-- TASK-012: Autocmd system conformance
-- Tests nvim_create_augroup, nvim_create_autocmd, nvim_exec_autocmds.

local out = {}

-- Test creating autocmd group
local group = vim.api.nvim_create_augroup("TestGroup", {clear = true})
out.group_created = group ~= nil

-- Test creating autocmd
local callback_executed = false
local autocmd = vim.api.nvim_create_autocmd("User", {
  group = "TestGroup",
  pattern = "TestEvent",
  callback = function()
    callback_executed = true
  end,
})
out.autocmd_created = autocmd ~= nil

-- Trigger the autocmd manually
vim.api.nvim_exec_autocmds("User", {pattern = "TestEvent"})
out.callback_executed = callback_executed

-- Test multiple events
local count = 0
vim.api.nvim_create_autocmd({"User"}, {
  group = "TestGroup",
  pattern = "MultiEvent",
  callback = function()
    count = count + 1
  end,
})

-- Trigger multiple times
vim.api.nvim_exec_autocmds("User", {pattern = "MultiEvent"})
vim.api.nvim_exec_autocmds("User", {pattern = "MultiEvent"})
vim.api.nvim_exec_autocmds("User", {pattern = "MultiEvent"})
out.multiple_events = count

io.stdout:write(vim.json.encode(out) .. "\n")
