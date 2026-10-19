-- TASK-108: Autocmds fire on editor actions

local api = vim.api
local out = {}
local path = '/tmp/zigvim_autocmd_test.txt'
os.remove(path)

local log = {}
local function record(a)
  log[#log + 1] = {event = a.event, match_ok = a.match:match('zigvim_autocmd_test%.txt$') ~= nil, has_buf = type(a.buf) == 'number'}
end

api.nvim_create_autocmd({'BufWritePre', 'BufWritePost'}, {pattern = '*.txt', callback = record})
api.nvim_create_autocmd('BufWritePost', {pattern = '*.txt', command = "let g:autocmd_wrote = 'yes'"})

local ft
api.nvim_create_autocmd('FileType', {
  pattern = 'lua',
  callback = function(a)
    ft = {match = a.match, filetype = vim.bo.filetype}
  end,
})

vim.cmd('edit ' .. path)
api.nvim_buf_set_lines(0, 0, -1, false, {'hello', 'world'})
vim.cmd('silent write')
vim.cmd('set filetype=lua')

out.log = log
out.ft = ft
out.wrote = vim.g.autocmd_wrote
out.content = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '|')
out.modified = vim.bo.modified

os.remove(path)
io.stdout:write(vim.json.encode(out) .. "\n")
