-- vim.diff() / vim.text.diff(): Myers line diff with xdiff-compatible output.
-- Neovim uses the xdiff C library; this matches its hunks for the common cases
-- (ambiguous insert/delete hunks slide down as far as possible, like
-- xdl_change_compact) and its 'unified' / 'indices' output and on_hunk calls.
-- shortcut: algorithm, linematch and indent_heuristic are accepted but every diff
-- is plain Myers; very large rewrites are O(N*D) in Lua. Upgrade by vendoring xdiff.

local M = {}

local function split_lines(s)
  local lines = {}
  if s == '' then
    return lines
  end
  for line in s:gmatch('([^\n]*)\n') do
    lines[#lines + 1] = line
  end
  local tail = s:match('([^\n]*)$')
  if tail ~= '' then
    lines[#lines + 1] = tail .. '\0noeol' -- differs from the same text with a newline
  end
  return lines
end

local function normalizer(opts)
  local f = function(l)
    return l
  end
  if opts.ignore_whitespace then
    f = function(l)
      return (l:gsub('%s', ''))
    end
  elseif opts.ignore_whitespace_change then
    f = function(l)
      return (l:gsub('%s+', ' '):gsub('%s+$', ''))
    end
  elseif opts.ignore_whitespace_change_at_eol then
    f = function(l)
      return (l:gsub('%s+$', ''))
    end
  end
  if opts.ignore_cr_at_eol then
    local g = f
    f = function(l)
      return g((l:gsub('\r$', '')))
    end
  end
  return f
end

-- Shortest edit script between a[lo_a..hi_a] and b[lo_b..hi_b] (Myers 1986):
-- V is snapshotted before each step, then the path is walked back from (n, m).
-- Returns the matched pairs as two parallel lists of indices.
local function myers(a, b, lo_a, hi_a, lo_b, hi_b)
  local n, m = hi_a - lo_a + 1, hi_b - lo_b + 1
  if n <= 0 or m <= 0 then
    return {}, {}
  end
  local v, trace = { [1] = 0 }, {}
  local final
  for d = 0, n + m do
    local snap = {}
    for k, x in pairs(v) do
      snap[k] = x
    end
    trace[d] = snap
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and v[k - 1] < v[k + 1]) then
        x = v[k + 1]
      else
        x = v[k - 1] + 1
      end
      local y = x - k
      while x < n and y < m and a[lo_a + x] == b[lo_b + y] do
        x, y = x + 1, y + 1
      end
      v[k] = x
      if x >= n and y >= m then
        final = d
        break
      end
    end
    if final then
      break
    end
  end
  local ma, mb = {}, {}
  local x, y = n, m
  for d = final, 0, -1 do
    local vd = trace[d]
    local k = x - y
    local pk
    if k == -d or (k ~= d and vd[k - 1] < vd[k + 1]) then
      pk = k + 1
    else
      pk = k - 1
    end
    local px = vd[pk]
    local py = px - pk
    while x > px and y > py and x > 0 and y > 0 do
      x, y = x - 1, y - 1
      table.insert(ma, 1, lo_a + x)
      table.insert(mb, 1, lo_b + y)
    end
    x, y = px, py
  end
  return ma, mb
end

-- Hunks as { sa, ca, sb, cb } (1-based starts; a zero count uses the line before).
local function compute_hunks(a, b)
  local na, nb = #a, #b
  local pre = 0
  while pre < na and pre < nb and a[pre + 1] == b[pre + 1] do
    pre = pre + 1
  end
  local suf = 0
  while suf < na - pre and suf < nb - pre and a[na - suf] == b[nb - suf] do
    suf = suf + 1
  end
  -- matched index pairs, in order
  local ma, mb = {}, {}
  for i = 1, pre do
    ma[#ma + 1], mb[#mb + 1] = i, i
  end
  local ia, ib = myers(a, b, pre + 1, na - suf, pre + 1, nb - suf)
  for i = 1, #ia do
    ma[#ma + 1], mb[#mb + 1] = ia[i], ib[i]
  end
  for i = suf - 1, 0, -1 do
    ma[#ma + 1], mb[#mb + 1] = na - i, nb - i
  end
  ma[#ma + 1], mb[#mb + 1] = na + 1, nb + 1 -- sentinel

  local hunks = {}
  local pa, pb = 0, 0
  for i = 1, #ma do
    local xa, xb = ma[i], mb[i]
    if xa > pa + 1 or xb > pb + 1 then
      hunks[#hunks + 1] = { pa + 1, xa - pa - 1, pb + 1, xb - pb - 1 }
    end
    pa, pb = xa, xb
  end

  -- Slide pure insertions/deletions down while the next line repeats the first.
  for i, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local next_h = hunks[i + 1]
    if ca == 0 and cb > 0 then
      while sb + cb <= nb and b[sb] == b[sb + cb] and sa <= na and (not next_h or sa + 1 < next_h[1]) do
        sa, sb = sa + 1, sb + 1
      end
    elseif cb == 0 and ca > 0 then
      while sa + ca <= na and a[sa] == a[sa + ca] and sb <= nb and (not next_h or sb + 1 < next_h[3]) do
        sa, sb = sa + 1, sb + 1
      end
    end
    h[1], h[3] = sa, sb
  end
  for _, h in ipairs(hunks) do
    if h[2] == 0 then
      h[1] = h[1] - 1
    end
    if h[4] == 0 then
      h[3] = h[3] - 1
    end
  end
  return hunks
end

local function range(start, count)
  if count == 1 then
    return tostring(start)
  end
  return start .. ',' .. count
end

local function show(line, sign, out)
  local text, noeol = line:gsub('%z' .. 'noeol$', '')
  out[#out + 1] = sign .. text .. '\n'
  if noeol > 0 then
    out[#out + 1] = '\\ No newline at end of file\n'
  end
end

local function unified(a, b, hunks, ctx)
  local out = {}
  local i = 1
  while i <= #hunks do
    -- group hunks whose context would touch
    local j = i
    while j < #hunks do
      local cur, nxt = hunks[j], hunks[j + 1]
      local cur_end = cur[1] + (cur[2] == 0 and 1 or cur[2])
      local nxt_start = nxt[1] + (nxt[2] == 0 and 1 or 0)
      if nxt_start - cur_end > 2 * ctx then
        break
      end
      j = j + 1
    end
    local first, last = hunks[i], hunks[j]
    local a_lo = (first[2] == 0 and first[1] + 1 or first[1])
    local a_hi = (last[2] == 0 and last[1] or last[1] + last[2] - 1)
    local b_lo = (first[4] == 0 and first[3] + 1 or first[3])
    local start_a = math.max(1, a_lo - ctx)
    local end_a = math.min(#a, a_hi + ctx)
    local start_b = math.max(1, b_lo - (a_lo - start_a))
    local count_a = end_a - start_a + 1
    local count_b = count_a
    for k = i, j do
      count_b = count_b - hunks[k][2] + hunks[k][4]
    end
    local hs_a = count_a == 0 and start_a - 1 or start_a
    local hs_b = count_b == 0 and start_b - 1 or start_b
    if ctx == 0 then
      hs_a = first[2] == 0 and first[1] or first[1]
      hs_b = first[4] == 0 and first[3] or first[3]
    end
    out[#out + 1] = '@@ -' .. range(hs_a, count_a) .. ' +' .. range(hs_b, count_b) .. ' @@\n'
    local pa = start_a
    for k = i, j do
      local h = hunks[k]
      local del_from = h[2] == 0 and h[1] + 1 or h[1]
      for l = pa, del_from - 1 do
        show(a[l], ' ', out)
      end
      for l = h[1], h[1] + h[2] - 1 do
        if h[2] > 0 then
          show(a[l], '-', out)
        end
      end
      for l = h[3], h[3] + h[4] - 1 do
        if h[4] > 0 then
          show(b[l], '+', out)
        end
      end
      pa = del_from + h[2]
    end
    for l = pa, end_a do
      show(a[l], ' ', out)
    end
    i = j + 1
  end
  return table.concat(out)
end

function M.diff(a, b, opts)
  opts = opts or {}
  local la, lb = split_lines(a), split_lines(b)
  local norm = normalizer(opts)
  local ka, kb = {}, {}
  for i, l in ipairs(la) do
    ka[i] = norm(l)
  end
  for i, l in ipairs(lb) do
    kb[i] = norm(l)
  end
  local hunks = compute_hunks(ka, kb)
  if opts.ignore_blank_lines then
    hunks = vim.tbl_filter(function(h)
      for l = h[1], h[1] + h[2] - 1 do
        if h[2] > 0 and la[l]:find('%S') then
          return true
        end
      end
      for l = h[3], h[3] + h[4] - 1 do
        if h[4] > 0 and lb[l]:find('%S') then
          return true
        end
      end
      return false
    end, hunks)
  end
  if opts.on_hunk then
    for _, h in ipairs(hunks) do
      if opts.on_hunk(h[1], h[2], h[3], h[4]) == -1 then
        error('diff operation failed') -- what Neovim's xdiff binding does after the stop
      end
    end
    return nil
  end
  if opts.result_type == 'indices' then
    return hunks
  end
  return unified(la, lb, hunks, opts.ctxlen or 0)
end

return M
