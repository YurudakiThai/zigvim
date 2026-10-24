-- TASK-149: nvim_buf_get_text and nvim_buf_attach on_bytes (tree-sitter's incremental reparse uses both).
local res = { text = {}, bytes = {} }
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abcd', 'efgh', 'ij' })
for _, a in ipairs({ { 0, 1, 1, 2 }, { 0, 0, 0, -1 }, { -1, 0, -1, -1 }, { 0, -2, 1, -1 }, { 0, 2, 0, 2 }, { 1, 0, 3, 0 }, { 0, 9, 0, 9 }, { 1, 0, 0, 0 }, { 0, 0, 2, 2 }, { -4, 0, 0, 1 } }) do
  local ok, r = pcall(vim.api.nvim_buf_get_text, 0, a[1], a[2], a[3], a[4], {})
  res.text[#res.text + 1] = { ok, ok and r or tostring(r):gsub('^.-: ', '') }
end
local function reset() vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abc', 'de', 'fghi' }) end
reset()
local out = {}
vim.api.nvim_buf_attach(0, false, { on_bytes = function(...) out[#out + 1] = table.concat({ select(4, ...) }, ',') end })
local cases = {
  function() vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'X', 'YY' }) end,
  function() vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'top' }) end,
  function() vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'end' }) end,
  function() vim.api.nvim_buf_set_lines(0, 1, 3, false, {}) end,
  function() vim.api.nvim_buf_set_lines(0, 0, -1, false, {}) end,
  function() vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b' }) end,
  function() vim.api.nvim_buf_set_lines(0, 2, 3, false, {}) end,
  function() vim.api.nvim_buf_set_text(0, 0, 1, 1, 1, { 'Q' }) end,
  function() vim.api.nvim_buf_set_text(0, 1, 0, 1, 0, { 'p', 'q' }) end,
  function() vim.api.nvim_buf_set_text(0, 2, 4, 2, 4, { '!' }) end,
}
for _, f in ipairs(cases) do
  reset()
  out = {}
  f()
  res.bytes[#res.bytes + 1] = table.concat(out, ' | ')
end
io.stdout:write(vim.json.encode(res) .. '\n')
