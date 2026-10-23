-- TASK-121: vim.fn.keytrans, as AstroNvim uses it: keytrans(replace_termcodes(lhs))

vim.g.mapleader = ' '
local keys = {
  '<Leader>ff', '<leader>q', '<C-H>', '<c-s>', '<F7>', '<C-Space>', '<cr>', '<Esc>',
  '<Tab>', '<S-Tab>', '<M-x>', '<Up>', '<BS>', 'gx', '<lt>', '\\', '|', 'é',
  '<F17>', '<f29>', '<S-F17>', '<C-J>', '<C-j>', '<C-M>', '<C-I>', '<C-[>', '<C-@>', '<NL>', '<C-^>', '<C-]>',
}
local out = {}
for i, k in ipairs(keys) do
  out[i] = vim.fn.keytrans(vim.api.nvim_replace_termcodes(k, true, true, true))
end
-- raw bytes straight into keytrans
local raw = { 'a b', '\r', '\27', '<', '\1', '\t', '<Leader>x' }
local out_raw = {}
for i, k in ipairs(raw) do
  out_raw[i] = vim.fn.keytrans(k)
end

io.stdout:write(vim.json.encode({ out = out, raw = out_raw }) .. "\n")
