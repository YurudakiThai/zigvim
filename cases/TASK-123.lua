-- TASK-123: vendored LPeg as vim.lpeg / require('lpeg'), plus vim.re and the LSP snippet grammar

local lpeg = vim.lpeg
local P, R, C, Ct = lpeg.P, lpeg.R, lpeg.C, lpeg.Ct
local digits = C(R('09') ^ 1)
local list = Ct(digits * (P(',') * digits) ^ 0)

local grammar = require('vim.lsp._snippet_grammar')
local snip = grammar.parse('foo(${1:bar}, $2)$0')
local kinds = {}
for i, node in ipairs(snip.data.children) do
  kinds[i] = node.type
end

io.stdout:write(vim.json.encode({
  same = vim.lpeg == require('lpeg'),
  version = lpeg.version,
  list = list:match('10,20,3'),
  nomatch = lpeg.match(P('x'), 'abc') == nil,
  re = vim.re.match('hello world', '{%a+} " " {%a+}'),
  re_find = vim.re.find('the quick fox', "'quick'"),
  snippet_kinds = kinds,
}) .. "\n")
