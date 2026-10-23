-- TASK-136: extmark sign queries (sign column) and getregionpos (vim.hl.range, diagnostics)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello', 'b', '' })
local a = vim.api.nvim_create_namespace('a136')
local b = vim.api.nvim_create_namespace('b136')
vim.api.nvim_buf_set_extmark(0, a, 0, 0, { sign_text = '+', sign_hl_group = 'DiffAdd' })
vim.api.nvim_buf_set_extmark(vim.api.nvim_get_current_buf(), b, 2, 0, { sign_text = 'W', priority = 10 })
vim.api.nvim_buf_set_extmark(0, b, 1, 0, { hl_group = 'Search', end_col = 1 })

local function rows(marks)
  local t = {}
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    t[#t + 1] = { m[2], m[3], d.sign_text, d.priority, d.ns_id == a and 'a' or d.ns_id == b and 'b' or nil }
  end
  return t
end

local region = {}
for _, c in ipairs({
  { { 0, 1, 1, 0 }, { 0, 1, 1, 0 }, { type = 'v', exclusive = true } },
  { { 0, 1, 2, 0 }, { 0, 1, 4, 0 }, { type = 'v', exclusive = true } },
  { { 0, 1, 1, 0 }, { 0, 2, 1, 0 }, { type = 'v', exclusive = true } },
  { { 0, 1, 1, 0 }, { 0, 3, 1, 0 }, { type = 'v', exclusive = true } },
  { { 0, 1, 4, 0 }, { 0, 1, 2, 0 }, { type = 'v', exclusive = true } },
  { { 0, 3, 1, 0 }, { 0, 3, 1, 0 }, { type = 'v', exclusive = true } },
  { { 0, 1, 1, 0 }, { 0, 1, 2147483647, 0 }, { type = 'v', exclusive = false } },
  { { 0, 2, 1, 0 }, { 0, 1, 1, 0 }, { type = 'V' } },
}) do
  region[#region + 1] = vim.fn.getregionpos(c[1], c[2], c[3])
end

local sparse = {}
for _, t in ipairs({ { 1, nil, 3 }, { [1] = 1, [5] = 5 }, { [2] = 1 }, { [1] = 1, [11] = 1 }, { [1.5] = 1 }, {} }) do
  local ok, r = pcall(vim.json.encode, t)
  sparse[#sparse + 1] = ok and r or tostring(r)
end

io.stdout:write(vim.json.encode({
  sparse = sparse,
  all = rows(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })),
  signs = rows(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true, type = 'sign' })),
  upto_row1 = #vim.api.nvim_buf_get_extmarks(0, -1, { 0, 0 }, { 1, -1 }, {}),
  upto_row2 = #vim.api.nvim_buf_get_extmarks(0, -1, { 0, 0 }, { 2, -1 }, {}),
  ns_only = #vim.api.nvim_buf_get_extmarks(0, b, 0, -1, {}),
  region = region,
}) .. "\n")
