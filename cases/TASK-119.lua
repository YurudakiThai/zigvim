-- TASK-119: nvim_set_hl without an explicit cterm copies gui attrs into cterm

vim.api.nvim_set_hl(0, 'TestHl119', { fg = '#ff0000', bold = true, italic = true })
vim.api.nvim_set_hl(0, 'TestHl119b', { bold = true, cterm = { underline = true } })
vim.api.nvim_set_hl(0, 'TestHl119c', { fg = '#00ff00' })

local function norm(hl)
  return { bold = hl.bold, italic = hl.italic, fg = hl.fg, cterm = hl.cterm }
end

io.stdout:write(vim.json.encode({
  a = norm(vim.api.nvim_get_hl(0, { name = 'TestHl119' })),
  b = norm(vim.api.nvim_get_hl(0, { name = 'TestHl119b' })),
  c = norm(vim.api.nvim_get_hl(0, { name = 'TestHl119c' })),
}) .. "\n")
