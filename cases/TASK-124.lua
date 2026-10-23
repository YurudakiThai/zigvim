-- TASK-124: vim.version is the runtime module and reports Neovim 0.12.6

local v = vim.version()
io.stdout:write(vim.json.encode({
  kind = type(vim.version),
  -- not tostring(v): its '+build' suffix depends on how the oracle nvim was built
  str = string.format('%d.%d.%d', v.major, v.minor, v.patch),
  api_level = vim.fn.api_info().version.api_level,
  in_range = vim.version.range('0.12.0 - 0.12.1'):has(v),
  ge = vim.version.ge(v, { 0, 10, 0 }),
  cmp = vim.version.cmp('1.2.3', '1.10.0'),
  parse = tostring(vim.version.parse('v2.3.4-beta')),
  has12 = vim.fn.has('nvim-0.12'),
  has13 = vim.fn.has('nvim-0.13'),
}) .. "\n")
