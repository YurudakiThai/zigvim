-- TASK-133: vim.uv.spawn / new_pipe / new_check / kill and vim.system on top of them

local uv = vim.uv

-- raw luv: stdin -> cat -> stdout, stderr, exit code
local out, err, exit = {}, {}, nil
local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
local handle, pid = uv.spawn('sh', { args = { '-c', 'cat; echo err >&2; exit 3' }, stdio = { stdin, stdout, stderr } },
  function(code, signal) exit = { code, signal } end)
stdout:read_start(function(_, d) if d then out[#out + 1] = d end end)
stderr:read_start(function(_, d) if d then err[#err + 1] = d end end)
stdin:write({ 'hello ', 'world\n' })
stdin:shutdown(function() stdin:close() end)
vim.wait(5000, function() return exit ~= nil end)
local raw = { table.concat(out), table.concat(err), exit, type(pid), handle:is_closing() }
handle:close()
local closed = { stdin:is_closing() }

local fail = { uv.spawn('/no/such/bin', {}, function() end) }

-- check handles run once per loop iteration
local ticks = 0
local check = uv.new_check()
check:start(function() ticks = ticks + 1 end)
vim.wait(2000, function() return ticks >= 1 end)
check:stop()
check:close()

-- vim.system
local function sys(cmd, opts)
  local r = vim.system(cmd, opts):wait()
  return { r.code, r.signal, r.stdout, r.stderr }
end
local async
vim.system({ 'echo', 'async' }, {}, function(o) async = o.stdout end)
vim.wait(5000, function() return async ~= nil end)
local ok_missing, err_missing = pcall(vim.system, { 'no_such_cmd_133' })
local killed = vim.system({ 'sleep', '5' })
killed:kill('sigterm')
local k = killed:wait()

io.stdout:write(vim.json.encode({
  raw = raw,
  closed = closed,
  fail = { fail[1] == nil, fail[2], fail[3] },
  ticks = ticks >= 1,
  text = sys({ 'sh', '-c', 'printf "a\\r\\nb"; echo oops >&2; exit 2' }, { text = true }),
  stdin = sys({ 'cat' }, { stdin = 'piped in' }),
  stdin_list = sys({ 'cat' }, { stdin = { 'l1', 'l2' } }),
  async = async,
  missing = { ok_missing, tostring(err_missing):match('ENOENT.*') },
  timeout = sys({ 'sleep', '5' }, { timeout = 100 }),
  kill = { k.code, k.signal },
  cwd = sys({ 'pwd' }, { cwd = '/', text = true }),
  env = sys({ 'sh', '-c', 'echo $ZV_X' }, { env = { ZV_X = 'yes' }, text = true }),
}) .. "\n")
