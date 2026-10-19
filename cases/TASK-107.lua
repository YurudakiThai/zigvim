-- TASK-107: Autocmd API conformance

local api = vim.api
local out = {}

local function simple(list)
  local res = {}
  for i, a in ipairs(list) do
    res[i] = {
      event = a.event,
      group = a.group,
      pattern = a.pattern,
      desc = a.desc,
      once = a.once,
      nested = a.nested,
      command = a.command,
      buffer = a.buffer,
      has_cb = type(a.callback) == 'function',
    }
  end
  return res
end

local g1 = api.nvim_create_augroup('ZGroup', {clear = true})
local g2 = api.nvim_create_augroup('ZGroup', {clear = true})
out.group_stable = g1 == g2
local other = api.nvim_create_augroup('Other', {})
out.group_distinct = other ~= g1
out.group_other_stable = api.nvim_create_augroup('Other', {}) == other

local hits = {}
local id = api.nvim_create_autocmd({'BufWritePre', 'BufWritePost'}, {
  group = g1,
  pattern = '*.lua',
  callback = function(args)
    hits[#hits + 1] = {event = args.event, match = args.match, id_ok = args.id ~= nil}
  end,
  desc = 'test hook',
})
out.created = type(id) == 'number'

local list = simple(api.nvim_get_autocmds({group = g1}))
out.list_count = #list
out.list_events = {list[1].event, list[2].event}
out.list_desc = list[1].desc
out.list_has_cb = list[1].has_cb
out.list_command = list[1].command
out.list_pattern = list[1].pattern
out.list_group = list[1].group == g1

out.event_error = select(2, pcall(api.nvim_get_autocmds, {event = 'NoSuchEvent'}))
api.nvim_del_autocmd(id)
out.deleted_count = #api.nvim_get_autocmds({group = g1})
out.delete_twice_ok = pcall(api.nvim_del_autocmd, id)

local cmd_id = api.nvim_create_autocmd('User', {
  pattern = 'ZigEvent',
  command = "let g:zig_aug = 'ran'",
})
out.command_created = type(cmd_id) == 'number'
api.nvim_exec_autocmds('User', {pattern = 'ZigEvent'})
out.command_ran = vim.g.zig_aug

local bufid = api.nvim_get_current_buf()
local buf_hits = {}
api.nvim_create_autocmd('User', {
  buffer = bufid,
  callback = function(a)
    buf_hits[#buf_hits + 1] = {event = a.event, match = a.match, buf = a.buf}
  end,
})
api.nvim_exec_autocmds('User', {pattern = 'Hello'})
out.buffer_hits = buf_hits

local once_count = 0
api.nvim_create_autocmd('User', {
  pattern = 'Once',
  once = true,
  callback = function()
    once_count = once_count + 1
  end,
})
api.nvim_exec_autocmds('User', {pattern = 'Once'})
api.nvim_exec_autocmds('User', {pattern = 'Once'})
out.once_count = once_count

local data_seen
api.nvim_create_autocmd('User', {
  pattern = 'DataEvent',
  callback = function(a)
    data_seen = a.data
  end,
})
api.nvim_exec_autocmds('User', {pattern = 'DataEvent', data = {value = 7}})
out.data = data_seen

api.nvim_clear_autocmds({event = 'User'})
out.after_clear = #api.nvim_get_autocmds({event = 'User'})
out.other_group_kept = #api.nvim_get_autocmds({group = other})

io.stdout:write(vim.json.encode(out) .. "\n")
