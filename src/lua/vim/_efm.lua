-- 'errorformat' parsing for getqflist({lines = ...}) / setqflist (nvim-lint's
-- from_errorformat relies on it). Each format becomes an anchored Lua pattern.
-- Supported: %f %l %c %e %k %v %m %t %n %s %p %r %%, %*[...] / %*d / %*s skips,
-- %. and %# (Vim regex . and *), \, literal commas, prefixes %E %W %I %N %A %C %Z %G
-- and the %- / %+ modifiers.
-- shortcut: no %O/%P/%Q directory/file stacks, no %> and no general Vim-regex
-- atoms besides %. and %#; upgrade when a linter's 'errorformat' needs them.

local M = {}

local function split_formats(efm)
  local out, cur, i = {}, {}, 1
  while i <= #efm do
    local ch = efm:sub(i, i)
    if ch == '\\' and efm:sub(i + 1, i + 1) == ',' then
      cur[#cur + 1] = ','
      i = i + 2
    elseif ch == ',' then
      out[#out + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = ch
      i = i + 1
    end
  end
  out[#out + 1] = table.concat(cur)
  return out
end

local magic = '^$()%.[]*+-?'

local function lit(ch)
  return magic:find(ch, 1, true) and ('%' .. ch) or ch
end

-- One format -> { kind, flag, pattern, fields } where fields lists the capture roles.
local function compile(fmt)
  local kind, flag = nil, nil
  local f = fmt
  local m, k = f:match('^%%([%-+]?)([EWINACZGOPQ])')
  if k then
    flag, kind = (m ~= '' and m or nil), k
    f = f:sub(#m + 3)
  end
  local pat, fields, i = { '^' }, {}, 1
  local n = #f
  while i <= n do
    local ch = f:sub(i, i)
    if ch == '%' then
      local c = f:sub(i + 1, i + 1)
      i = i + 2
      local last = i > n
      if c == 'f' then
        pat[#pat + 1] = last and '(.+)' or '(.-)'
        fields[#fields + 1] = 'f'
      elseif c == 'l' or c == 'c' or c == 'e' or c == 'k' or c == 'n' or c == 'v' then
        pat[#pat + 1] = '(%d+)'
        fields[#fields + 1] = c
      elseif c == 'm' or c == 'r' then
        pat[#pat + 1] = last and '(.*)' or '(.-)'
        fields[#fields + 1] = c
      elseif c == 's' and f:sub(i, i + 1) == '%#' then
        -- %s%#: Vim's starred lazy group ends on an empty capture, so no pattern
        pat[#pat + 1] = '.-'
        i = i + 2
      elseif c == 's' then
        pat[#pat + 1] = last and '(.*)' or '(.-)'
        fields[#fields + 1] = 's'
      elseif c == 't' then
        pat[#pat + 1] = '(.)'
        fields[#fields + 1] = 't'
      elseif c == 'p' then
        pat[#pat + 1] = '([%- %.]*)'
        fields[#fields + 1] = 'p'
      elseif c == '%' then
        pat[#pat + 1] = '%%'
      elseif c == '.' then
        pat[#pat + 1] = '.'
      elseif c == '>' then
        -- %> marks where a retry starts; nothing to match
      elseif c == '[' then
        -- %[...]: a Vim collection; %^ inside is a literal/negating ^
        local body = f:match('^(.-)%]', i)
        if body then
          i = i + #body + 1
          body = body:gsub('%%%^', '^')
          local neg = body:sub(1, 1) == '^'
          if neg then
            body = body:sub(2)
          end
          body = body:gsub('[%%%]%-]', '%%%0')
          pat[#pat + 1] = '[' .. (neg and '^' or '') .. body .. ']'
        else
          pat[#pat + 1] = '%['
        end
      elseif c == '#' then
        pat[#pat + 1] = '*'
      elseif c == '*' then
        -- scanf-style skip: %*[...] or %*d / %*s / %*\d
        local set = f:match('^%[[^%]]*%]', i)
        if set then
          pat[#pat + 1] = set:gsub('%%', '%%%%') .. '*'
          i = i + #set
        else
          local d = f:sub(i, i)
          if d == '\\' then
            d = f:sub(i + 1, i + 1)
            i = i + 1
          end
          pat[#pat + 1] = d == 'd' and '%d*' or (d == 's' and '%s*' or '.-')
          i = i + 1
        end
      else
        pat[#pat + 1] = lit(c)
      end
    elseif ch == '\\' then
      pat[#pat + 1] = lit(f:sub(i + 1, i + 1))
      i = i + 2
    else
      pat[#pat + 1] = lit(ch)
      i = i + 1
    end
  end
  return { kind = kind, flag = flag, pat = table.concat(pat), full = table.concat(pat) .. '$', fields = fields }
end

local function new_item()
  return { bufnr = 0, lnum = 0, end_lnum = 0, col = 0, end_col = 0, vcol = 0, nr = -1, pattern = '', text = '', type = '', valid = 1, module = '' }
end

local function apply(item, fmt, caps, line)
  for j, role in ipairs(fmt.fields) do
    local v = caps[j]
    if role == 'f' and v ~= '' then
      item.bufnr = vim.fn.bufadd(v)
    elseif role == 'l' then
      item.lnum = tonumber(v)
    elseif role == 'c' then
      item.col = tonumber(v)
    elseif role == 'v' then
      item.col, item.vcol = tonumber(v), 1
    elseif role == 'e' then
      item.end_lnum = tonumber(v)
    elseif role == 'k' then
      item.end_col = tonumber(v)
    elseif role == 'n' then
      item.nr = tonumber(v)
    elseif role == 't' then
      item.type = v
    elseif role == 'm' then
      -- a continuation line always joins with a newline, even onto an empty message
      item.text = item._multi and (item.text .. '\n' .. v) or v
    elseif role == 's' and v ~= '' then
      item.pattern = '^\\V' .. v .. '\\$'
    elseif role == 'p' then
      item.col, item.vcol = #v + 1, 1
    end
  end
  if fmt.flag == '+' then
    item.text = (item.text ~= '' and item.text .. '\n' or '') .. line
  end
end

function M.parse(efm, lines)
  local fmts = {}
  for _, f in ipairs(split_formats(efm)) do
    if f ~= '' then
      fmts[#fmts + 1] = compile(f)
    end
  end
  local items, open = {}, nil
  for _, line in ipairs(lines) do
    local done = false
    -- inside a multi-line message, ending (%Z) then continuation (%C) formats win
    local order = fmts
    if open then
      order = {}
      for _, want in ipairs({ 'Z', 'C' }) do
        for _, f in ipairs(fmts) do
          if f.kind == want then
            order[#order + 1] = f
          end
        end
      end
      for _, f in ipairs(fmts) do
        if f.kind ~= 'Z' and f.kind ~= 'C' then
          order[#order + 1] = f
        end
      end
    end
    for _, fmt in ipairs(order) do
      local k = fmt.kind
      local multi = k == 'C' or k == 'Z'
      if not multi or open then
        local caps
        local matched
        if k == 'Z' then
          matched = line:match(fmt.full) ~= nil
          caps = { line:match(fmt.full) }
        else
          matched = line:match(fmt.pat) ~= nil
          caps = { line:match(fmt.pat) }
        end
        if matched then
          if caps[1] == line and #fmt.fields == 0 then
            caps = {}
          end
          if fmt.flag == '-' then
            if k == 'Z' then
              open = nil
            end
          elseif k == 'C' then
            open._multi = true
            apply(open, fmt, caps, line)
          elseif k == 'Z' then
            open._multi = true
            apply(open, fmt, caps, line)
            open = nil
          elseif k == 'E' or k == 'W' or k == 'I' or k == 'N' or k == 'A' then
            local item = new_item()
            item.type = (k == 'A') and '' or k
            apply(item, fmt, caps, line)
            items[#items + 1] = item
            open = item
          elseif k == 'G' then
            -- general message lines: included only with %+G
            if fmt.flag == '+' then
              local item = new_item()
              item.text, item.valid = line, 0
              items[#items + 1] = item
            end
          else
            local item = new_item()
            apply(item, fmt, caps, line)
            items[#items + 1] = item
            open = nil
          end
          done = true
          break
        end
      end
    end
    if not done then
      open = nil
      local item = new_item()
      item.text, item.valid = line, 0
      items[#items + 1] = item
    end
  end
  for _, item in ipairs(items) do
    item._multi = nil
  end
  return items
end

return M
