-- TASK-142: str_utf_start/end/pos, bufadd/bufload/bufloaded, vim.glob / vim.ui present

local s = 'aé😀b'
local se = {}
for i = 1, #s do
  se[#se + 1] = { vim.str_utf_start(s, i), vim.str_utf_end(s, i) }
end
local b = vim.fn.bufadd('/tmp/zz_bufadd_142.txt')
local before = { vim.fn.bufloaded(b), vim.api.nvim_buf_is_loaded(b), vim.api.nvim_buf_line_count(b), vim.fn.buflisted(b) }
local load_ret = vim.fn.bufload(b)
local after = { vim.fn.bufloaded(b), vim.api.nvim_buf_is_loaded(b) }

io.stdout:write(vim.json.encode({
  se = se,
  pos = { vim.str_utf_pos(s), vim.str_utf_pos('') },
  bad = { pcall(vim.str_utf_start, s, 0), (select(2, pcall(vim.str_utf_start, s, 99))):match('index out of range') },
  before = before,
  load_ret = load_ret,
  after = after,
  name = vim.api.nvim_buf_get_name(b):match('zz_bufadd_142.txt$'),
  same = vim.fn.bufadd('/tmp/zz_bufadd_142.txt') == b,
  rel = vim.fn.bufadd('rel142/x.txt') == vim.fn.bufadd(vim.fn.getcwd() .. '/rel142/x.txt'),
  empty_new = vim.fn.bufadd('') ~= vim.fn.bufadd(''),
  glob = vim.glob.to_lpeg('*.lua'):match('x.lua') ~= nil,
  ui = { type(vim.ui.select), type(vim.ui.input), type(vim.ui.open) },
}) .. "\n")
