-- TASK-122: nvim_get_runtime_file('') keeps dirs as-is; vim.fn.environ

local d = vim.fn.tempname()
vim.fn.mkdir(d .. '/a', 'p')
vim.fn.mkdir(d .. '/b', 'p')
vim.o.rtp = d .. '/a/,' .. d .. '/b,' .. d .. '/missing'
local once = vim.api.nvim_get_runtime_file('', true)
vim.o.rtp = table.concat(once, ',')
local twice = vim.api.nvim_get_runtime_file('', true)
local function rel(list)
  local out = {}
  for i, p in ipairs(list) do
    out[i] = p:sub(#d + 1)
  end
  return out
end
local env = vim.fn.environ()

io.stdout:write(vim.json.encode({
  once = rel(once),
  twice = rel(twice),
  env_home = env.HOME == os.getenv('HOME'),
  env_type = type(env),
}) .. "\n")
