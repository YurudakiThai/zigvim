-- TASK-148: tree-sitter (vendored library + Neovim's Lua bindings): parse a buffer and a
-- string, run the bundled highlight query, incremental reparse after an edit, captures at a position.
local out = {}
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local x = { 1, "two" }', '-- note', 'function f(a) return a end' })
vim.bo.filetype = 'lua'
local parser = vim.treesitter.get_parser(0, 'lua')
local tree = parser:parse()[1]
out.sexpr = tree:root():sexpr()
out.range = { tree:root():range() }
local q = vim.treesitter.query.get('lua', 'highlights')
local caps = {}
for id, node in q:iter_captures(tree:root(), 0, 0, -1) do
  local r1, c1, r2, c2 = node:range()
  caps[#caps + 1] = table.concat({ q.captures[id], r1, c1, r2, c2 }, ' ')
end
out.captures = caps
vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'local y = x' })
tree = parser:parse()[1]
out.sexpr2 = tree:root():sexpr()
local node = vim.treesitter.get_node({ bufnr = 0, pos = { 2, 9 } })
out.node = node and { node:type(), node:named(), node:parent():type() }
local at = {}
for _, c in ipairs(vim.treesitter.get_captures_at_pos(0, 0, 1)) do
  at[#at + 1] = c.capture .. '@' .. c.lang
end
out.at = at
out.str = vim.treesitter.get_string_parser('int main(void) { return 0; }', 'c'):parse()[1]:root():sexpr()
out.has = { vim.treesitter.language.add('markdown'), (pcall(vim.treesitter.language.add, 'nosuchlang')) }
local ok, err = pcall(vim.treesitter.query.parse, 'lua', '(nosuchnode) @x')
out.qerr = { ok, (tostring(err):gsub('^.-: ', '')) }
io.stdout:write(vim.json.encode(out) .. '\n')
