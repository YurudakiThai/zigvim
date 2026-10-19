-- TASK-105: Keymap and user-command API conformance

local out = {}

local function find_map(list, lhs)
  for _, map in ipairs(list) do
    if map.lhs == lhs then
      return map
    end
  end
  return nil
end

local lhs = "<Plug>(zigvim-test)"
vim.api.nvim_set_keymap("n", lhs, ":echo 1<CR>", {noremap = true, silent = true, desc = "test"})
local map = find_map(vim.api.nvim_get_keymap("n"), lhs)
out.global_map = {
  lhs = map.lhs,
  rhs = map.rhs,
  mode = map.mode,
  noremap = map.noremap,
  silent = map.silent,
  desc = map.desc,
}

vim.api.nvim_del_keymap("n", lhs)
out.after_del = find_map(vim.api.nvim_get_keymap("n"), lhs) == nil

local cb_lhs = "<Plug>(zigvim-callback)"
vim.keymap.set("n", cb_lhs, function() end, {desc = "cb"})
local cb = find_map(vim.api.nvim_get_keymap("n"), cb_lhs)
out.callback_map = {
  lhs = cb.lhs,
  has_callback = type(cb.callback) == "function",
  desc = cb.desc,
}
vim.keymap.del("n", cb_lhs)
out.after_cb_del = find_map(vim.api.nvim_get_keymap("n"), cb_lhs) == nil

local buf_lhs = "<Plug>(zigvim-buffer)"
vim.api.nvim_buf_set_keymap(0, "n", buf_lhs, ":echo 2<CR>", {})
out.buffer_map = find_map(vim.api.nvim_buf_get_keymap(0, "n"), buf_lhs) ~= nil
vim.api.nvim_buf_del_keymap(0, "n", buf_lhs)
out.after_buffer_del = find_map(vim.api.nvim_buf_get_keymap(0, "n"), buf_lhs) == nil

local cmd_args
vim.api.nvim_create_user_command("ZigTest", function(opts)
  cmd_args = opts.args
end, {nargs = "*", desc = "zig test command"})
out.has_command = vim.api.nvim_get_commands({}).ZigTest ~= nil
vim.cmd("ZigTest hello world")
out.command_args = cmd_args
vim.api.nvim_del_user_command("ZigTest")
out.command_deleted = vim.api.nvim_get_commands({}).ZigTest == nil

io.stdout:write(vim.json.encode(out) .. "\n")
