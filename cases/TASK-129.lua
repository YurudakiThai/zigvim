-- TASK-129: APIs plugins hit when the TUI opens a file (flash, mini.pairs, mason, noice,
-- bufferline, trouble, user configs): maparg, sha256, findfile, nvim_get_hl_by_name,
-- vim.opt scalar options, vim.w[win], :nohlsearch / :redraw

local sha = {}
for _, n in ipairs({ 0, 3, 55, 56, 63, 64, 65, 200 }) do
  sha[#sha + 1] = vim.fn.sha256(string.rep('a', n))
end
sha[#sha + 1] = vim.fn.sha256('abc')

local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/a/b', 'p')
vim.fn.writefile({}, root .. '/CMakeLists.txt')
vim.fn.writefile({}, root .. '/a/note.txt')
vim.fn.chdir(root .. '/a/b')
local function rel(p)
  return p == '' and '' or vim.fn.resolve(p):sub(#vim.fn.resolve(root) + 1)
end
local ff = {
  rel(vim.fn.findfile('CMakeLists.txt', '.;')),
  rel(vim.fn.findfile('note.txt', '.;')),
  rel(vim.fn.findfile('nope.txt', '.;')),
  rel(vim.fn.findfile('CMakeLists.txt')),
  rel(vim.fn.findfile('note.txt', '..')),
}

vim.keymap.set('n', 'Q', 'dd', { desc = 'x' })
vim.keymap.set('n', '<C-k>', function() end)
local d = vim.fn.maparg('Q', 'n', false, true)

vim.api.nvim_set_hl(0, 'X129', { fg = '#ff0000', bold = true })
local ok_bad, err_bad = pcall(vim.api.nvim_get_hl_by_name, 'NoSuchGrp129', true)

local w = vim.api.nvim_get_current_win()
vim.w[w].v129 = 5

io.stdout:write(vim.json.encode({
  sha = sha,
  findfile = ff,
  maparg = { vim.fn.maparg('Q', 'n'), vim.fn.maparg('nomap', 'n'), vim.fn.maparg('<C-k>', 'n') ~= '' },
  maparg_dict = { d.lhs, d.rhs, d.desc, d.noremap, d.mode, d.abbr, d.lhsraw },
  maparg_none = vim.tbl_isempty(vim.fn.maparg('nomap', 'n', false, true)),
  hl_rgb = vim.api.nvim_get_hl_by_name('X129', true),
  hl_cterm = vim.api.nvim_get_hl_by_name('X129', false),
  hl_bad = { ok_bad, err_bad },
  opt = { vim.opt.termguicolors:get(), vim.opt.tabstop:get(), type(vim.opt.number) },
  wvar = { vim.w[w].v129, vim.w[0].v129, vim.w.v129 },
  cmds = { vim.fn.exists(':nohlsearch'), vim.fn.exists(':redraw'), pcall(vim.cmd, 'nohlsearch'), pcall(vim.cmd, 'redraw!') },
}) .. "\n")
