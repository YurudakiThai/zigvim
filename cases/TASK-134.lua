-- TASK-134: vim.diff / vim.text.diff match Neovim's xdiff (gitsigns' internal diff)

local fixed = {
  { 'a\nb\n', 'a\nc\nd\n' }, { 'x\nx\n', 'x\n' }, { 'x\n', 'x\nx\n' }, { 'a\nb\nc\n', 'a\nc\n' },
  { '', 'a\n' }, { 'a\n', '' }, { 'a\nb\nc\nd\ne\nf\ng\n', 'a\nB\nc\nd\ne\nF\ng\n' },
  { 'a\n\nb\n\nc\n', 'a\n\nb\n\nb\n\nc\n' }, { 'a\nb', 'a\nb\n' }, { '  a\nb\n', 'a\nb\n' }, { 'same\n', 'same\n' },
}
local out = { fixed = {} }
for i, c in ipairs(fixed) do
  out.fixed[i] = {
    vim.diff(c[1], c[2], { result_type = 'indices' }),
    vim.diff(c[1], c[2]),
    vim.diff(c[1], c[2], { ctxlen = 3 }),
  }
end
out.text_diff = vim.text.diff('a\nb\n', 'a\nB\n')
out.iw = vim.diff('  a\nb\n', 'a\nb\n', { result_type = 'indices', ignore_whitespace = true })
out.hunks = {}
vim.diff('a\nb\nc\n', 'A\nb\nC\n', { on_hunk = function(...) table.insert(out.hunks, { ... }) end })
out.stop = {}
local ok_stop, err_stop = pcall(vim.diff, 'a\nb\nc\n', 'A\nb\nC\n', { on_hunk = function(...) table.insert(out.stop, { ... }) return -1 end })
out.stop_err = { ok_stop, tostring(err_stop):match('diff operation failed') }

-- Random files over a tiny alphabet: ambiguous diffs everywhere (own LCG, so both
-- editors see the same inputs).
local seed = 12345
local function rnd(n)
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed % n
end
local function file()
  local t = {}
  for i = 1, rnd(12) do
    t[i] = ({ 'a', 'b', 'c' })[rnd(3) + 1]
  end
  return #t > 0 and table.concat(t, '\n') .. '\n' or ''
end
-- Placement of ambiguous hunks can differ from xdiff (see src/lua/vim/_diff.lua), so
-- compare what both must satisfy: applying the hunks to a gives b.
local function lines(s)
  local t = {}
  for l in s:gmatch('([^\n]*)\n') do
    t[#t + 1] = l
  end
  return t
end
local function apply(a, b, hunks)
  local la, lb, res, ia = lines(a), lines(b), {}, 1
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local upto = ca == 0 and sa or sa - 1
    while ia <= upto do
      res[#res + 1] = la[ia]
      ia = ia + 1
    end
    ia = ia + ca
    for l = sb, sb + cb - 1 do
      if cb > 0 then
        res[#res + 1] = lb[l]
      end
    end
  end
  while ia <= #la do
    res[#res + 1] = la[ia]
    ia = ia + 1
  end
  return vim.deep_equal(res, lb)
end
local bad = 0
for _ = 1, 300 do
  local a, b = file(), file()
  if not apply(a, b, vim.diff(a, b, { result_type = 'indices' })) then
    bad = bad + 1
  end
end
out.random_bad = bad

io.stdout:write(vim.json.encode(out) .. "\n")
