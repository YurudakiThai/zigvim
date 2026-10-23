-- TASK-125: built-in highlight groups, nvim_get_hl link=false, hlexists, :hi clear / :hi link

local function count()
  local n = 0
  for _ in pairs(vim.api.nvim_get_hl(0, {})) do
    n = n + 1
  end
  return n
end

local before = count()
vim.api.nvim_set_hl(0, 'Normal', { fg = '#112233' })
vim.api.nvim_set_hl(0, 'MyGroup125', { bold = true, fg = '#445566' })
vim.cmd('hi link MyLink125 MyGroup125')
vim.cmd('hi default link MyLink125 Comment') -- default does not override an existing link
local linked = vim.api.nvim_get_hl(0, { name = 'MyLink125' })
local resolved = vim.api.nvim_get_hl(0, { name = 'MyLink125', link = false })
local exists = {
  vim.fn.hlexists('Normal'), vim.fn.hlexists('normal'), vim.fn.hlexists('@comment'),
  vim.fn.hlexists('DiagnosticError'), vim.fn.hlexists('MyGroup125'), vim.fn.hlexists('NoSuch125'),
}
vim.cmd('hi clear')
local after_clear = count()

-- set_hl replaces unless update=true; default=true keeps a defined group
vim.api.nvim_set_hl(0, 'Rep125', { fg = '#ff0000', italic = true })
vim.api.nvim_set_hl(0, 'Rep125', { bold = true })
local replaced = vim.api.nvim_get_hl(0, { name = 'Rep125' })
vim.api.nvim_set_hl(0, 'Rep125', { underline = true, update = true })
local updated = vim.api.nvim_get_hl(0, { name = 'Rep125' })
vim.api.nvim_set_hl(0, 'Rep125', { default = true, fg = '#00ff00' })
local kept = vim.api.nvim_get_hl(0, { name = 'Rep125' })
vim.api.nvim_set_hl(0, 'Cterm125', { ctermfg = 3, blend = 0, bg = '#000000' })

io.stdout:write(vim.json.encode({
  replaced = replaced,
  updated = updated,
  kept = kept,
  cterm = vim.api.nvim_get_hl(0, { name = 'Cterm125' }),
  before = before,
  after_clear = after_clear,
  normal_after_clear = vim.api.nvim_get_hl(0, { name = 'Normal' }),
  mygroup_after_clear = vim.api.nvim_get_hl(0, { name = 'MyGroup125' }),
  linked = linked,
  resolved = resolved,
  exists = exists,
  diag = vim.api.nvim_get_hl(0, { name = 'DiagnosticError' }),
  comment_ts = vim.api.nvim_get_hl(0, { name = '@comment', link = false }),
}) .. "\n")
