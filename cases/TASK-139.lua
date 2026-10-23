-- TASK-139: changedtick, nvim_buf_set_text, uv.os_getpid

local b = vim.api.nvim_get_current_buf()
local ticks = { vim.api.nvim_buf_get_changedtick(0) }
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello world', 'second' })
ticks[#ticks + 1] = vim.api.nvim_buf_get_changedtick(0)
ticks[#ticks + 1] = vim.b.changedtick
vim.api.nvim_buf_set_text(0, 0, 6, 0, 11, { 'there' })
ticks[#ticks + 1] = vim.b[b].changedtick
local after1 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
vim.api.nvim_buf_set_text(0, 0, 5, 1, 3, { '!', 'new', '' })
local after2 = vim.api.nvim_buf_get_lines(0, 0, -1, false)
vim.api.nvim_buf_set_text(0, 0, 0, 0, 0, {})
local nb = vim.api.nvim_create_buf(true, false)
local bad = { pcall(vim.api.nvim_buf_set_text, 0, 0, 3, 0, 1, { 'x' }) }
local bad2 = { pcall(vim.api.nvim_buf_set_text, 0, 9, 0, 9, 0, { 'x' }) }

io.stdout:write(vim.json.encode({
  ticks = ticks,
  new_buf_tick = vim.api.nvim_buf_get_changedtick(nb),
  get_var = vim.api.nvim_buf_get_var(0, 'changedtick') == vim.api.nvim_buf_get_changedtick(0),
  after1 = after1,
  after2 = after2,
  final = vim.api.nvim_buf_get_lines(0, 0, -1, false),
  bad = { bad[1], tostring(bad[2]):match("'start' is higher than 'end'") },
  bad2 = bad2[1],
  pid = type(vim.uv.os_getpid()) == 'number' and vim.uv.os_getpid() > 0,
  ppid = type(vim.uv.os_getppid()) == 'number',
}) .. "\n")
