-- TASK-120: nvim_eval for mapping <expr>s, typed registers, v:exiting

local exprs = {
  "v:count == 0 ? 'gj' : 'j'",
  "'Nn'[v:searchforward].'zv'",
  "'nN'[v:searchforward]",
  "1 + 2 * 3",
  "'a' .. 'b' . 'c'",
  "!0 && (2 > 1 || 0)",
  "'x' ==# 'X'",
  "'x' ==? 'X'",
  "'it''s'",
  '"a\\tb"',
  "&tabstop",
  "-7 / 2",
}
local evals = {}
for i, e in ipairs(exprs) do
  evals[i] = vim.api.nvim_eval(e)
end

vim.fn.setreg('a', "x\ny\n")
vim.fn.setreg('b', { 'q' })
vim.fn.setreg('c', 'q')
vim.fn.setreg('d', 'q', 'l')

io.stdout:write(vim.json.encode({
  evals = evals,
  exiting_nil = vim.v.exiting == vim.NIL,
  types = { vim.fn.getregtype('a'), vim.fn.getregtype('b'), vim.fn.getregtype('c'), vim.fn.getregtype('d'), vim.fn.getregtype('z') },
  a = vim.fn.getreg('a'),
  a_list = vim.fn.getreg('a', 1, 1),
  d = vim.fn.getreg('d'),
}) .. "\n")
