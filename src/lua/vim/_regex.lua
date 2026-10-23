-- vim.regex(): a backtracking engine for Vim's regex syntax (Neovim uses Vim's C
-- engine). Covers magic and very magic (\v) patterns, \c/\C, character classes,
-- [] collections, groups and \|, *, \+, \=, \?, \{n,m} (and lazy \{-n,m}),
-- \< \>, ^ $, \zs \ze and the \@= \@! \@<= \@<! lookarounds.
-- shortcut: \M/\V are treated as magic, \%d/\%x/\%V/\%[ and back-references are
-- not supported, and matching recurses once per character (fine for lines, not
-- for megabyte strings). Upgrade when a plugin needs more.

local M = {}

local function cls(fn)
  return { t = 'set', fn = fn }
end

local function is_word(c)
  return c and c:match('^[%w_]$') ~= nil or (c and c:byte() >= 0x80) or false
end

local classes = {
  s = function(c) return c == ' ' or c == '\t' end,
  d = function(c) return c:match('%d') ~= nil end,
  w = function(c) return c:match('[%w_]') ~= nil end,
  a = function(c) return c:match('%a') ~= nil end,
  l = function(c) return c:match('%l') ~= nil end,
  u = function(c) return c:match('%u') ~= nil end,
  x = function(c) return c:match('%x') ~= nil end,
  o = function(c) return c:match('[0-7]') ~= nil end,
  h = function(c) return c:match('[%a_]') ~= nil end,
  k = function(c) return is_word(c) end,
  i = function(c) return is_word(c) end,
  f = function(c) return c:match('[%w/%.%-_+,#$%%~=]') ~= nil or c:byte() >= 0x80 end,
  p = function(c) return c:byte() >= 32 and c:byte() ~= 127 end,
}

local posix = {
  alpha = '%a', digit = '%d', alnum = '%w', lower = '%l', upper = '%u', space = '%s',
  punct = '%p', xdigit = '%x', cntrl = '%c', print = '[%g ]', graph = '%g', blank = '[ \t]',
}

local escapes = { t = '\t', n = '\n', e = '\27', r = '\r', b = '\b' }

-- Parser: pattern -> node tree. Nodes: seq, alt, char, any, set, bol, eol, bow,
-- eow, group, rep, look, zs, ze.
local function parse(pat)
  local pos, very = 1, false
  local flags = { icase = nil }
  local n = #pat

  local function peek(o)
    return pat:sub(pos + (o or 0), pos + (o or 0))
  end

  -- Reads one "token": returns kind and value. Kinds that depend on magic-ness are
  -- normalised here.
  local function token()
    local c = peek()
    if c == '' then
      return nil
    end
    if c == '\\' then
      local d = peek(1)
      pos = pos + 2
      if d == 'v' then
        very = true
        return 'mode'
      elseif d == 'm' or d == 'M' or d == 'V' then
        very = false
        return 'mode'
      elseif d == 'c' then
        flags.icase = true
        return 'mode'
      elseif d == 'C' then
        flags.icase = false
        return 'mode'
      elseif d == 'z' then
        local e = peek()
        pos = pos + 1
        if e == 's' then
          return 'zs'
        elseif e == 'e' then
          return 'ze'
        end
        error('E68: Invalid character after \\z')
      elseif d == '%' then
        if peek() == '(' then
          pos = pos + 1
          return 'open', false
        elseif peek() == '^' then
          pos = pos + 1
          return 'bof'
        elseif peek() == '$' then
          pos = pos + 1
          return 'eof'
        end
        error('E71: Invalid character after \\%')
      elseif classes[d] then
        return 'atom', cls(classes[d])
      elseif classes[d:lower()] and d:match('%u') then
        local f = classes[d:lower()]
        return 'atom', cls(function(ch) return not f(ch) end)
      elseif escapes[d] then
        return 'atom', { t = 'char', c = escapes[d] }
      end
      if very then
        return 'atom', { t = 'char', c = d } -- \v: an escaped special is literal
      end
      if d == '(' then
        return 'open', true
      elseif d == ')' then
        return 'close'
      elseif d == '|' then
        return 'alt'
      elseif d == '+' or d == '=' or d == '?' then
        return 'multi', d
      elseif d == '{' then
        return 'brace'
      elseif d == '@' then
        return 'look'
      elseif d == '<' then
        return 'bow'
      elseif d == '>' then
        return 'eow'
      end
      return 'atom', { t = 'char', c = d }
    end
    pos = pos + 1
    if very then
      if c == '(' then
        return 'open', true
      elseif c == '%' and peek() == '(' then
        pos = pos + 1
        return 'open', false
      elseif c == ')' then
        return 'close'
      elseif c == '|' then
        return 'alt'
      elseif c == '+' or c == '=' or c == '?' then
        return 'multi', c
      elseif c == '{' then
        return 'brace'
      elseif c == '@' then
        return 'look'
      elseif c == '<' then
        return 'bow'
      elseif c == '>' then
        return 'eow'
      end
    end
    if c == '*' then
      return 'multi', '*'
    elseif c == '.' then
      return 'atom', { t = 'any' }
    elseif c == '[' then
      return 'bracket'
    elseif c == '^' then
      return 'caret'
    elseif c == '$' then
      return 'dollar'
    end
    return 'atom', { t = 'char', c = c }
  end

  local function bracket()
    local start = pos
    local negate = false
    if peek() == '^' then
      negate = true
      pos = pos + 1
    end
    local items = {}
    local first = true
    while true do
      local c = peek()
      if c == '' then
        pos = start - 1 -- unterminated: '[' is a literal
        pos = pos + 1
        return { t = 'char', c = '[' }
      end
      if c == ']' and not first then
        pos = pos + 1
        break
      end
      first = false
      local lo
      if c == '[' and peek(1) == ':' then
        local name, stop = pat:match('^%[:(%a+):%]()', pos)
        if name and posix[name] then
          local p = posix[name]
          items[#items + 1] = function(ch) return ch:match(p) ~= nil end
          pos = stop
          goto continue
        end
      end
      if c == '\\' then
        local d = peek(1)
        pos = pos + 2
        lo = escapes[d] or d
      else
        pos = pos + 1
        lo = c
      end
      if peek() == '-' and peek(1) ~= ']' and peek(1) ~= '' then
        pos = pos + 1
        local hi = peek()
        if hi == '\\' then
          hi = escapes[peek(1)] or peek(1)
          pos = pos + 2
        else
          pos = pos + 1
        end
        local a, b = lo:byte(), hi:byte()
        items[#items + 1] = function(ch) local x = ch:byte() return x >= a and x <= b end
      else
        local lit = lo
        items[#items + 1] = function(ch) return ch == lit end
      end
      ::continue::
    end
    return cls(function(ch)
      for _, f in ipairs(items) do
        if f(ch) then
          return not negate
        end
      end
      return negate
    end)
  end

  local function brace()
    local lazy = false
    if peek() == '-' then
      lazy = true
      pos = pos + 1
    end
    local body, stop = pat:match('^([%d,]*)\\?}()', pos)
    if not body then
      error('E554: Syntax error in \\{...}')
    end
    pos = stop
    local lo, comma, hi = body:match('^(%d*)(,?)(%d*)$')
    local min = tonumber(lo) or 0
    local max
    if comma == '' then
      max = lo ~= '' and min or math.huge
    else
      max = tonumber(hi) or math.huge
    end
    return min, max, lazy
  end

  local parse_alt

  local function parse_seq()
    local seq = {}
    local at_start = true
    while true do
      local save = pos
      local kind, val = token()
      if kind == nil or kind == 'alt' or kind == 'close' then
        pos = save
        break
      end
      local node
      if kind == 'mode' then
        -- no node
      elseif kind == 'atom' then
        node = val
      elseif kind == 'bracket' then
        node = bracket()
      elseif kind == 'open' then
        node = { t = 'group', body = parse_alt() }
        local k2 = token()
        if k2 ~= 'close' then
          error('E54: Unmatched \\(')
        end
      elseif kind == 'caret' then
        node = at_start and { t = 'bol' } or { t = 'char', c = '^' }
      elseif kind == 'dollar' then
        -- special only at the end of a branch
        local look_pos = pos
        local k2 = token()
        pos = look_pos
        node = (k2 == nil or k2 == 'alt' or k2 == 'close') and { t = 'eol' } or { t = 'char', c = '$' }
      elseif kind == 'bof' then
        node = { t = 'bol' }
      elseif kind == 'eof' then
        node = { t = 'eol' }
      elseif kind == 'bow' then
        node = { t = 'bow' }
      elseif kind == 'eow' then
        node = { t = 'eow' }
      elseif kind == 'zs' then
        node = { t = 'zs' }
      elseif kind == 'ze' then
        node = { t = 'ze' }
      elseif kind == 'multi' or kind == 'brace' or kind == 'look' then
        local prev = seq[#seq]
        if not prev then
          if kind == 'multi' and val == '*' then
            node = { t = 'char', c = '*' } -- leading * is literal
          else
            error('E64: ' .. tostring(val or kind) .. ' follows nothing')
          end
        else
          seq[#seq] = nil
          if kind == 'multi' then
            local min, max = 0, math.huge
            if val == '+' then
              min = 1
            elseif val == '=' or val == '?' then
              max = 1
            end
            node = { t = 'rep', atom = prev, min = min, max = max }
          elseif kind == 'brace' then
            local min, max, lazy = brace()
            node = { t = 'rep', atom = prev, min = min, max = max, lazy = lazy }
          else
            local spec = pat:match('^<?[=!>]', pos)
            if not spec then
              error('E64: invalid \\@')
            end
            pos = pos + #spec
            node = { t = 'look', atom = prev, behind = spec:sub(1, 1) == '<', neg = spec:sub(-1) == '!', atomic = spec == '>' }
          end
        end
      end
      if node then
        seq[#seq + 1] = node
        at_start = false
      end
    end
    return { t = 'seq', items = seq }
  end

  parse_alt = function()
    local alts = { parse_seq() }
    while true do
      local save = pos
      local kind = token()
      if kind ~= 'alt' then
        pos = save
        break
      end
      alts[#alts + 1] = parse_seq()
    end
    return #alts == 1 and alts[1] or { t = 'alt', alts = alts }
  end

  local tree = parse_alt()
  if pos <= n then
    error('E55: Unmatched \\)')
  end
  return tree, flags.icase
end

-- Compiler: node -> function(i, k) that calls k(next_i) and returns its result.
local function compile(node, st)
  local t = node.t
  if t == 'seq' then
    local fns = {}
    for i, item in ipairs(node.items) do
      fns[i] = compile(item, st)
    end
    local function run(idx, i, k)
      if idx > #fns then
        return k(i)
      end
      return fns[idx](i, function(j)
        return run(idx + 1, j, k)
      end)
    end
    return function(i, k)
      return run(1, i, k)
    end
  elseif t == 'alt' then
    local fns = {}
    for i, a in ipairs(node.alts) do
      fns[i] = compile(a, st)
    end
    return function(i, k)
      for _, f in ipairs(fns) do
        local r = f(i, k)
        if r then
          return r
        end
      end
    end
  elseif t == 'group' then
    return compile(node.body, st)
  elseif t == 'char' then
    local c = node.c
    return function(i, k)
      local ch = st.s:sub(i, i)
      if ch == c or (st.icase and ch:lower() == c:lower()) then
        return k(i + 1)
      end
    end
  elseif t == 'any' then
    return function(i, k)
      local ch = st.s:sub(i, i)
      if ch ~= '' and ch ~= '\n' then
        local len = #(st.s:match('^[%z\1-\127\194-\244][\128-\191]*', i) or ch)
        return k(i + len)
      end
    end
  elseif t == 'set' then
    local fn = node.fn
    return function(i, k)
      local ch = st.s:match('^[%z\1-\127\194-\244][\128-\191]*', i)
      if ch and ch ~= '' and (fn(ch) or (st.icase and (fn(ch:lower()) or fn(ch:upper())))) then
        return k(i + #ch)
      end
    end
  elseif t == 'bol' then
    return function(i, k)
      if i == 1 then
        return k(i)
      end
    end
  elseif t == 'eol' then
    return function(i, k)
      if i == #st.s + 1 then
        return k(i)
      end
    end
  elseif t == 'bow' then
    return function(i, k)
      local cur, prev = st.s:sub(i, i), i > 1 and st.s:sub(i - 1, i - 1) or nil
      if cur ~= '' and is_word(cur) and not (prev and is_word(prev)) then
        return k(i)
      end
    end
  elseif t == 'eow' then
    return function(i, k)
      local cur, prev = st.s:sub(i, i), i > 1 and st.s:sub(i - 1, i - 1) or nil
      if prev and is_word(prev) and not (cur ~= '' and is_word(cur)) then
        return k(i)
      end
    end
  elseif t == 'zs' then
    return function(i, k)
      local old = st.zs
      st.zs = i
      local r = k(i)
      if not r then
        st.zs = old
      end
      return r
    end
  elseif t == 'ze' then
    return function(i, k)
      local old = st.ze
      st.ze = i
      local r = k(i)
      if not r then
        st.ze = old
      end
      return r
    end
  elseif t == 'rep' then
    local atom = compile(node.atom, st)
    local min, max, lazy = node.min, node.max, node.lazy
    return function(i, k)
      local function try(count, p)
        if lazy then
          if count >= min then
            local r = k(p)
            if r then
              return r
            end
          end
          if count < max then
            return atom(p, function(q)
              if q == p then
                return nil
              end
              return try(count + 1, q)
            end)
          end
          return nil
        end
        if count < max then
          local r = atom(p, function(q)
            if q == p then
              return nil -- an empty match would loop forever
            end
            return try(count + 1, q)
          end)
          if r then
            return r
          end
        end
        if count >= min then
          return k(p)
        end
      end
      return try(0, i)
    end
  elseif t == 'look' then
    local atom = compile(node.atom, st)
    return function(i, k)
      local found = false
      if node.behind then
        for j = i, 1, -1 do
          if atom(j, function(q) return q == i and q or nil end) then
            found = true
            break
          end
        end
      else
        local e = atom(i, function(q) return q end)
        found = e ~= nil
        if node.atomic then
          return e and k(e)
        end
      end
      if found ~= node.neg then
        return k(i)
      end
    end
  end
  error('internal: unknown node ' .. tostring(t))
end

function M.new(pat)
  local tree, icase = parse(pat)
  if icase == nil then
    icase = vim.o.ignorecase and not (vim.o.smartcase and pat:find('%u'))
  end
  local st = { icase = icase }
  local root = compile(tree, st)
  local re = {}

  local function match(s)
    st.s = s
    for start = 1, #s + 1 do
      st.zs, st.ze = nil, nil
      local e = root(start, function(i) return i end)
      if e then
        local ms = st.zs or start
        local me = st.ze or e
        return ms - 1, math.max(me, ms) - 1
      end
    end
  end

  function re.match_str(_, s)
    return match(tostring(s))
  end

  function re.match_line(_, buf, line, col_start, col_end)
    local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, true)[1] or ''
    col_start = col_start or 0
    text = text:sub(col_start + 1, col_end)
    local a, b = match(text)
    if a then
      return a, b
    end
  end

  return re
end

return M
