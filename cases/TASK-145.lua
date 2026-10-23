-- TASK-145: getqflist({efm, lines}) errorformat parsing (nvim-lint from_errorformat),
-- nvim_buf_clear_namespace ranges (stale diagnostic signs)

local hand = {
  { efm = 'stdin:%l:%c %m', lines = { 'stdin:7:1 x', 'garbage' } },
  { efm = '%f:%l:%c %m,%f:%l %m', lines = { 'a.md:3:5 MD001 heading', 'a.md:9 MD012 blank', 'noise' } },
  { efm = '%f:%l:%c: %t%*[^:]: %m', lines = { 'x.c:4:2: error: oops', 'x.c:5:1: warning: hmm' } },
  { efm = '%E%f:%l:%c: %m,%C%m,%Z', lines = { 'f.py:1:2: bad', '  more', '', 'tail' } },
  { efm = '%-Gignored%.%#,%f:%l:%m', lines = { 'ignored stuff', 'g.txt:2:msg' } },
  { efm = '%f|%l| %m', lines = { 'h.lua|10| text with | bar' } },
}
-- every 'errorformat' used by nvim-lint linters, with synthesized matching lines
local linter_cases = vim.json.decode([==[[{"efm": "%C%[%^^]%#,%E%>Parse error in %f:%l,%E%>Compile error in %f:%l,%-Z%p^%.%#,%C%m,%-G* %.%#", "lines": ["[^^]", ">Parse error in a.txt:3", ">Compile error in a.txt:3", "---^^q", "msg here", "* q", "totally unrelated line", ""]}, {"efm": "%E  Error: %m,%WWarning: %m,%C    at %f:%l:%c", "lines": ["  Error: msg here", "Warning: msg here", "    at a.txt:3:5", "totally unrelated line", ""]}, {"efm": "%E%f (%[%^ ]%# %l): %m,%C%p^,%C%.%#", "lines": ["a.txt ([^ ] 3): msg here", "---^^", "q", "totally unrelated line", ""]}, {"efm": "%E%m:,%C%f:%l:%c", "lines": ["msg here:", "a.txt:3:5", "totally unrelated line", ""]}, {"efm": "%N%f:%l%.%#,%Z%s%#D%n: %m", "lines": ["a.txt:3q", "patD12: msg here", "totally unrelated line", ""]}, {"efm": "%f:%l: %m", "lines": ["a.txt:3: msg here", "totally unrelated line", ""]}, {"efm": "%f:%l:%c: %m", "lines": ["a.txt:3:5: msg here", "totally unrelated line", ""]}, {"efm": "%f:%l:%c: %m,%f:%l: %m", "lines": ["a.txt:3:5: msg here", "a.txt:3: msg here", "totally unrelated line", ""]}, {"efm": "%f:%l:%c: %trror - %m", "lines": ["a.txt:3:5: Error - msg here", "totally unrelated line", ""]}, {"efm": "%f:%l:%c:%t:%n:%m", "lines": ["a.txt:3:5:E:12:msg here", "totally unrelated line", ""]}, {"efm": "%f:%l:%m", "lines": ["a.txt:3:msg here", "totally unrelated line", ""]}, {"efm": "%f:%t:%l:%c:%m", "lines": ["a.txt:E:3:5:msg here", "totally unrelated line", ""]}, {"efm": "%s:%l:%m", "lines": ["pat:3:msg here", "totally unrelated line", ""]}, {"efm": "(stdin):%l:1: warning: possible bashism; %m", "lines": ["(stdin):3:1: warning: possible bashism; msg here", "totally unrelated line", ""]}, {"efm": "<stdin>>%l:%c:%t:%n:%m", "lines": ["<stdin>>3:5:E:12:msg here", "totally unrelated line", ""]}, {"efm": "JSON5:\\ %m\\ at\\ %l:%c", "lines": ["JSON5: msg here at 3:5", "totally unrelated line", ""]}, {"efm": "bash:\\ line\\ %l:\\ %m", "lines": ["bash: line 3: msg here", "totally unrelated line", ""]}, {"efm": "ksh:\\ syntax\\ %t%.%#\\ at\\ line\\ %l:\\ %m,ksh:\\ %t%.%#\\ line\\ %l:\\ %m", "lines": ["ksh: syntax Eq at line 3: msg here", "ksh: Eq line 3: msg here", "totally unrelated line", ""]}, {"efm": "luac:\\ stdin:%l:\\ %m,%-G%.%#", "lines": ["luac: stdin:3: msg here", "q", "totally unrelated line", ""]}, {"efm": "stdin:%l:%c %m,stdin:%l %m", "lines": ["stdin:3:5 msg here", "stdin:3 msg here", "totally unrelated line", ""]}, {"efm": "stdin:%l:%c:%k: %m", "lines": ["stdin:3:5:6: msg here", "totally unrelated line", ""]}]]==])
for _, c in ipairs(hand) do
  linter_cases[#linter_cases + 1] = c
end
local cases = linter_cases
local out = {}
for i, c in ipairs(cases) do
  local ok, r = pcall(vim.fn.getqflist, { efm = c.efm, lines = c.lines })
  local items = {}
  for j, it in ipairs(ok and r.items or {}) do
    items[j] = table.concat({ it.bufnr > 0 and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(it.bufnr), ':t') or '', it.lnum, it.col, it.end_lnum, it.end_col, it.vcol, it.nr, it.text, it.type, it.valid, it.pattern }, '|')
  end
  out[i] = ok and table.concat(items, ' ## ') or ('ERR ' .. tostring(r))
end

local signs
do
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c', 'd' })
  local ns = vim.api.nvim_create_namespace('cn')
  for r = 0, 3 do vim.api.nvim_buf_set_extmark(0, ns, r, 0, { sign_text = 'E' }) end
  vim.api.nvim_buf_clear_namespace(0, ns, 1, 2)
  local a = #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
  vim.api.nvim_buf_clear_namespace(vim.api.nvim_get_current_buf(), ns, 2, -1)
  local b = #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
  for r = 0, 3 do vim.api.nvim_buf_set_extmark(0, ns, r, 0, {}) end
  vim.api.nvim_buf_clear_namespace(0, -1, 0, -1)
  local c = #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
  vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, message = 'x', severity = 1 } })
  local d = #vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { type = 'sign' })
  vim.diagnostic.set(ns, 0, {})
  local e = #vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { type = 'sign' })
  signs = { a, b, c, d, e }
end
io.stdout:write(vim.json.encode({ qf = out, signs = signs }) .. "\n")
