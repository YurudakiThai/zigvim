-- TASK-140: vim.str_utfindex / vim.str_byteindex (and the native helpers) — LSP position sync
local out = {}
for _, s in ipairs({ 'aé😀b', '', 'abc', '日本語', '😀😀', 'x\0y' }) do
  for i = 0, #s + 2 do
    local a, b = vim._str_utfindex(s, i)
    local c = { vim._str_byteindex(s, i, false) }
    local d = { vim._str_byteindex(s, i, true) }
    out[#out + 1] = s:gsub('%z', '0') .. '@' .. i .. '=' .. tostring(a) .. ',' .. tostring(b) .. '|' .. tostring(c[1]) .. '|' .. tostring(d[1])
  end
  local a, b = vim._str_utfindex(s)
  out[#out + 1] = s:gsub('%z', '0') .. '@all=' .. tostring(a) .. ',' .. tostring(b)
end
out[#out + 1] = 'api ' .. vim.str_utfindex('aé😀b', 'utf-16', 4) .. ' ' .. vim.str_byteindex('aé😀b', 'utf-16', 3) .. ' ' .. vim.str_utfindex('aé😀b', 'utf-32')
io.stdout:write(vim.json.encode(out) .. "\n")
