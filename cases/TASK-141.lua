-- TASK-141: on_lines line numbers, nvim_get_option_info2 / nvim_get_all_options_info, bufloaded

local log = {}
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c' })
vim.api.nvim_buf_attach(0, false, { on_lines = function(_, _, _, f, l, nl) log[#log + 1] = { f, l, nl } end })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'x', 'y' })
vim.api.nvim_buf_set_lines(0, -2, -1, false, { 'z' })
vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'ins1', 'ins2' })
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
vim.api.nvim_buf_set_text(0, 0, 1, 1, 0, { 'Q' })

local info = {}
for _, o in ipairs({ 'tagfunc', 'shiftwidth', 'number', 'clipboard', 'fileformat', 'sw', 'list', 'statusline', 'tabstop' }) do
  local i = vim.api.nvim_get_option_info2(o, {})
  info[o] = { i.name, i.shortname, i.scope, i.type, i.global_local, i.commalist, i.flaglist, i.default }
end
local all = vim.api.nvim_get_all_options_info()
local count = 0
for _ in pairs(all) do
  count = count + 1
end

io.stdout:write(vim.json.encode({
  on_lines = log,
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
  info = info,
  unknown = { pcall(vim.api.nvim_get_option_info2, 'nosuchopt', {}) },
  all_count = count,
  all_sample = { all.wrap.scope, all.wrap.shortname, all.ignorecase.type },
  bufloaded = { vim.fn.bufloaded(1), vim.fn.bufloaded(99), vim.fn.bufloaded('nonexistent') },
}) .. "\n")
