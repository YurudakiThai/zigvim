-- TASK-109: Shared Lua library (vim.tbl_*, list, string helpers, vim.NIL)

local out = {}

out.nil_type = type(vim.NIL)
out.json_nil = vim.json.encode(vim.NIL)
out.json_null_is_nil = vim.json.decode('null') == vim.NIL
out.json_null_roundtrip = vim.json.encode(vim.json.decode('{"a":null}'))
out.mpack_nil_errors = not (pcall(vim.mpack.encode, nil))
out.mpack_nil_roundtrip = vim.mpack.decode(vim.mpack.encode(vim.NIL)) == vim.NIL

out.tbl_keys = vim.tbl_keys({a = 1, b = 2})
table.sort(out.tbl_keys)
out.tbl_values = vim.tbl_values({a = 1, b = 2})
table.sort(out.tbl_values)
out.tbl_contains = {vim.tbl_contains({1, 2}, 2), vim.tbl_contains({1, 2}, 3)}
out.tbl_map = vim.tbl_map(function(x)
  return x * 2
end, {1, 2, 3})
out.tbl_filter = vim.tbl_filter(function(x)
  return x % 2 == 1
end, {1, 2, 3, 4})
out.tbl_extend = vim.tbl_extend('force', {a = 1}, {a = 2, b = 3})
out.tbl_deep_extend = vim.tbl_deep_extend('force', {a = {b = 1}}, {a = {c = 2}})
out.tbl_count = vim.tbl_count({a = 1, b = 2})
out.tbl_islist = {vim.islist({1, 2}), vim.islist({a = 1})}
out.tbl_get = vim.tbl_get({a = {b = 5}}, 'a', 'b')
out.tbl_isempty = {vim.tbl_isempty({}), vim.tbl_isempty({1})}
out.isarray = {vim.isarray({1, 2}), vim.isarray({a = 1})}

out.list_extend = vim.list_extend({1}, {2, 3})
out.list_slice = vim.list_slice({1, 2, 3, 4}, 2, 3)

out.split = vim.split('a,b,c', ',')
out.split_plain = vim.split('a.b.c', '.', {plain = true})
out.split_empty = vim.split('a,,b', ',', {plain = true})
out.gsplit = {}
for part in vim.gsplit('a,b,c', ',') do
  table.insert(out.gsplit, part)
end

out.trim = vim.trim('  x  ')
out.pesc = vim.pesc('a.b*c')
out.startswith = {vim.startswith('abc', 'ab'), vim.startswith('abc', 'b')}
out.endswith = {vim.endswith('abc', 'bc'), vim.endswith('abc', 'b')}
out.deep_equal = {vim.deep_equal({a = {1}}, {a = {1}}), vim.deep_equal({1}, {2})}
out.deepcopy = (function()
  local original = {a = {b = 1}}
  local copy = vim.deepcopy(original)
  copy.a.b = 2
  return {original = original.a.b, copy = copy.a.b}
end)()
out.is_callable = {vim.is_callable(function() end), vim.is_callable('x')}
out.stricmp = vim.stricmp('abc', 'ABC')

out.inspect = vim.inspect({1, 2})
out.version_has_fields = vim.version().major ~= nil
out.log_error = vim.log.levels.ERROR
out.deprecate_type = type(vim.deprecate)

io.stdout:write(vim.json.encode(out) .. '\n')
