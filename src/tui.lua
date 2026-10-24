-- zigvim terminal UI: a small modal editor built on the Neovim-compatible
-- API. Zig only provides raw terminal primitives (vim._tty_*); everything
-- else (keys, modes, motions, rendering) lives here so it can use the same
-- buffer/option/autocmd layers that plugins see.

local api = vim.api
local M = {}

local S = {
  mode = 'n', -- n, i, v (charwise visual), V (linewise visual)
  row = 1, -- cursor line (1-based)
  col = 0, -- cursor byte offset (0-based, start of a character)
  want = nil, -- desired display column for j/k (math.huge = end of line)
  top = 1,
  left = 0,
  msg = '',
  msg_err = false,
  cmdtype = nil,
  cmdtext = '',
  quit = false,
  queue = {},
  inject = {}, -- keys fed by noremap mappings; never mapped again
  from_inject = false,
  rbuf = '',
  pending_reg = nil, -- register named with a "x prefix for the current command
  in_normal = false, -- running :normal; an empty typeahead ends the command
  undo = {},
  redo = {},
  cur_snap = nil,
  changed = false,
  cur_keys = {},
  last_change = nil,
  anchor = nil,
  search = nil,
  find = nil,
  rows = 24,
  cols = 80,
  shape = nil,
}

-- ------------------------------------------------------------ utf-8 helpers

local LEAD = { [2] = 32, [3] = 16, [4] = 8 }

local function decode(s, i)
  local b = s:byte(i)
  if not b then
    return nil, 0
  end
  if b < 0x80 then
    return b, 1
  end
  local n = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
  if n == 1 or i + n - 1 > #s then
    return b, 1
  end
  local cp = b % LEAD[n]
  for j = 1, n - 1 do
    cp = cp * 64 + (s:byte(i + j) % 64)
  end
  return cp, n
end

local function is_cont(b)
  return b >= 0x80 and b < 0xC0
end

-- Zero-width code points: combining marks (including Thai vowels/tone marks),
-- zero-width joiners and variation selectors.
local function is_combining(cp)
  return (cp >= 0x300 and cp <= 0x36F)
    or cp == 0xE31
    or (cp >= 0xE34 and cp <= 0xE3A)
    or (cp >= 0xE47 and cp <= 0xE4E)
    or (cp >= 0x200B and cp <= 0x200F)
    or (cp >= 0xFE00 and cp <= 0xFE0F)
    or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x1DC0 and cp <= 0x1DFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE20 and cp <= 0xFE2F)
end

local function cp_width(cp)
  if is_combining(cp) then
    return 0
  end
  if
    (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF and cp ~= 0x303F)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
  then
    return 2
  end
  return 1
end

-- Start of the next character cluster (base char + combining marks).
local function next_col(s, col)
  local i = col + 1
  if i > #s then
    return #s
  end
  local _, n = decode(s, i)
  i = i + n
  while i <= #s do
    local cp, m = decode(s, i)
    if is_combining(cp) then
      i = i + m
    else
      break
    end
  end
  return i - 1
end

local function prev_col(s, col)
  if col <= 0 then
    return 0
  end
  if col > #s then
    col = #s
  end
  local j = col
  while true do
    while j > 1 and is_cont(s:byte(j)) do
      j = j - 1
    end
    if j <= 1 then
      break
    end
    local cp = decode(s, j)
    if not is_combining(cp) then
      break
    end
    j = j - 1
  end
  return j - 1
end

local function last_col(s)
  if #s == 0 then
    return 0
  end
  return prev_col(s, #s)
end

local function first_nonblank(s)
  local i = s:find('[^ \t]')
  if not i then
    return last_col(s)
  end
  return i - 1
end

local function str_width(s)
  local w = 0
  local i = 1
  while i <= #s do
    local cp, n = decode(s, i)
    w = w + cp_width(cp)
    i = i + n
  end
  return w
end

-- Split a line into display cells (tabs expanded, control chars as ^X).
local function cells(s)
  local out = {}
  local ts = vim.o.tabstop
  if type(ts) ~= 'number' or ts < 1 then
    ts = 8
  end
  local d = 0
  local i = 1
  local n = #s
  while i <= n do
    local cp, len = decode(s, i)
    local j = i + len
    local text = s:sub(i, j - 1)
    local w
    if cp == 9 then
      w = ts - (d % ts)
      text = (' '):rep(w)
    elseif cp < 32 then
      w = 2
      text = '^' .. string.char(cp + 64)
    elseif cp == 127 then
      w = 2
      text = '^?'
    elseif cp >= 0x80 and len == 1 then
      w = 1
      text = '?'
    else
      w = cp_width(cp)
      if w == 0 then
        w = 0
      end
    end
    while j <= n do
      local cp2, l2 = decode(s, j)
      if is_combining(cp2) then
        text = text .. s:sub(j, j + l2 - 1)
        j = j + l2
      else
        break
      end
    end
    out[#out + 1] = { b = i - 1, e = j - 1, d = d, w = w, t = text }
    d = d + w
    i = j
  end
  return out, d
end

-- Display column of the character starting at byte `col`.
local function display_col(s, col, normal)
  local cs, total = cells(s)
  for _, c in ipairs(cs) do
    if col >= c.b and col < c.e then
      if normal and c.w > 1 and s:byte(c.b + 1) == 9 then
        return c.d + c.w - 1
      end
      return c.d
    end
  end
  return total
end

-- Byte column of the character covering display column `dcol`.
local function col_for_display(s, dcol, insert)
  local cs, total = cells(s)
  if #cs == 0 then
    return 0
  end
  if dcol >= total then
    if insert then
      return #s
    end
    return cs[#cs].b
  end
  local found = cs[1].b
  for _, c in ipairs(cs) do
    if c.d <= dcol then
      found = c.b
    else
      break
    end
  end
  return found
end

local function is_special(k)
  return #k >= 3 and k:sub(1, 1) == '<' and k:sub(-1) == '>'
end

-- ------------------------------------------------------------ buffer access

local function nlines()
  return api.nvim_buf_line_count(0)
end

local function getline(n)
  return api.nvim_buf_get_lines(0, n - 1, n, false)[1] or ''
end

local function err(msg)
  S.msg = msg
  S.msg_err = true
  vim._msg_save(msg)
end

local function info(msg)
  S.msg = msg
  S.msg_err = false
  vim._msg_save(msg)
end

-- Undo summary in Neovim's words: "1 line less; before #3  0 seconds ago".
local function undo_message(old_lines, new_lines, seq, word, time)
  local delta = #new_lines - #old_lines
  local what
  if delta > 0 then
    what = delta == 1 and '1 more line' or (delta .. ' more lines')
  elseif delta < 0 then
    what = delta == -1 and '1 line less' or (-delta .. ' fewer lines')
  else
    local n = 0
    for i = 1, #new_lines do
      if new_lines[i] ~= old_lines[i] then
        n = n + 1
      end
    end
    n = math.max(n, 1)
    what = n == 1 and '1 change' or (n .. ' changes')
  end
  local age = math.floor((vim.uv.hrtime() - (time or vim.uv.hrtime())) / 1e9)
  local when = age < 100 and (age == 1 and '1 second ago' or (age .. ' seconds ago')) or os.date('%H:%M:%S', os.time() - age)
  return string.format('%s; %s #%d  %s', what, word, seq or 0, when)
end

local function snapshot()
  if S.cur_snap then
    return
  end
  S.cur_snap = { lines = api.nvim_buf_get_lines(0, 0, -1, false), row = S.row, col = S.col }
end

-- Replace lines [first0, last0) (0-based, end exclusive) with `repl`.
local function replace_lines(first0, last0, repl)
  snapshot()
  api.nvim_buf_set_lines(0, first0, last0, false, repl)
  if nlines() == 0 then
    api.nvim_buf_set_lines(0, 0, 0, false, { '' })
  end
end

local function clamp()
  local n = nlines()
  if S.row < 1 then
    S.row = 1
  end
  if S.row > n then
    S.row = n
  end
  local l = getline(S.row)
  if S.mode == 'i' then
    if S.col > #l then
      S.col = #l
    end
  else
    local lc = last_col(l)
    if S.col > lc then
      S.col = lc
    end
  end
  if S.col < 0 then
    S.col = 0
  end
end

local function set_cursor(row, col, keep_want)
  S.row, S.col = row, col
  if not keep_want then
    S.want = nil
  end
  clamp()
end

local function cur_dcol()
  return display_col(getline(S.row), S.col, S.mode ~= 'i')
end

-- ------------------------------------------------------------------ drawing

local function write(s)
  vim._tty_write(s)
end

local function mode_name()
  if S.mode == 'i' then
    return 'INSERT'
  elseif S.mode == 'v' then
    return 'VISUAL'
  elseif S.mode == 'V' then
    return 'V-LINE'
  end
  return 'NORMAL'
end

local function truncate(s, width)
  if str_width(s) <= width then
    return s
  end
  local out = {}
  local w = 0
  local i = 1
  while i <= #s do
    local cp, n = decode(s, i)
    local cw = cp_width(cp)
    if w + cw > width then
      break
    end
    out[#out + 1] = s:sub(i, i + n - 1)
    w = w + cw
    i = i + n
  end
  return table.concat(out)
end

-- `hl` (optional) maps a 0-based byte to the escape for its highlight ('' for none).
local function render_line(s, left, width, selfn, hl)
  local cs = cells(s)
  local buf = {}
  local rev = false
  local cur = ''
  for _, c in ipairs(cs) do
    local cstart, cend = c.d, c.d + c.w
    if cend > left and cstart < left + width and c.w > 0 then
      local text = c.t
      if cstart < left or cend > left + width then
        local from = math.max(cstart, left)
        local to = math.min(cend, left + width)
        text = (' '):rep(to - from)
      end
      local sel = selfn and selfn(c.b) or false
      local esc = hl and hl[c.b] or ''
      if sel ~= rev or esc ~= cur then
        buf[#buf + 1] = '\27[0m' .. esc .. (sel and '\27[7m' or '')
        rev, cur = sel, esc
      end
      buf[#buf + 1] = text
    elseif c.w == 0 and cstart >= left and cstart <= left + width then
      buf[#buf + 1] = c.t
    end
  end
  if rev or cur ~= '' then
    buf[#buf + 1] = '\27[0m'
  end
  return table.concat(buf)
end

local function visual_bounds()
  if not S.anchor then
    return nil
  end
  local ar, ac = S.anchor[1], S.anchor[2]
  local cr, cc = S.row, S.col
  if ar > cr or (ar == cr and ac > cc) then
    ar, ac, cr, cc = cr, cc, ar, ac
  end
  return ar, ac, cr, cc
end

-- Decoration providers (nvim_set_decoration_provider), called like Neovim's redraw:
-- on_start, on_buf, on_win with the visible rows (0-based), on_line per row, on_end.
-- A false return from on_start or on_win skips the rest for that provider.
local function run_decoration_providers(top, bot)
  local providers = vim._decoration_providers
  if not providers or next(providers) == nil then
    return
  end
  S.tick = (S.tick or 0) + 1
  vim._decor_ephemeral = S.ephemeral
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local ids = vim.tbl_keys(providers)
  table.sort(ids)
  for _, ns in ipairs(ids) do
    local p = providers[ns]
    local ok, res = true, nil
    if p.on_start then
      ok, res = pcall(p.on_start, 'start', S.tick)
    end
    if ok and res ~= false then
      if p.on_buf then
        pcall(p.on_buf, 'buf', buf, S.tick)
      end
      local wok, wres = true, nil
      if p.on_win then
        wok, wres = pcall(p.on_win, 'win', win, buf, top - 1, bot - 1)
      end
      if wok and wres ~= false and p.on_line then
        for row = top - 1, bot - 1 do
          pcall(p.on_line, 'line', win, buf, row)
        end
      end
      -- on_range, one whole line at a time; a returned (row, col) skips calls until there,
      -- false or an error stops calls for this window (Neovim's decor_providers_invoke_range).
      -- shortcut: whole lines only, Neovim may also split a long line into column ranges.
      if wok and wres ~= false and p.on_range then
        local skip_row, skip_col = -1, 0
        for row = top - 1, bot - 1 do
          if not (skip_row > row + 1 or (skip_row == row + 1 and skip_col >= 0)) then
            local rok, r1, r2 = pcall(p.on_range, 'range', win, buf, row, 0, row + 1, 0)
            if not rok or r1 == false then
              break
            elseif type(r1) == 'number' then
              skip_row, skip_col = r1, type(r2) == 'number' and r2 or 0
            end
          end
        end
      end
      if p.on_end then
        pcall(p.on_end, 'end', S.tick)
      end
    end
  end
  vim._decor_ephemeral = nil
end

-- Width of the sign column from 'signcolumn' ("yes", "yes:N", "auto", "auto:M-N", "no").
-- shortcut: "number" (signs drawn in the number column) shows no signs.
local function sign_width()
  local sc = tostring(vim.o.signcolumn or 'auto')
  if sc == 'no' or sc == 'number' then
    return 0
  end
  if sc:match('^yes') then
    return 2 * (tonumber(sc:match(':(%d+)$')) or 1)
  end
  local any = api.nvim_buf_get_extmarks(0, -1, 0, -1, { type = 'sign', limit = 1 })
  return #any > 0 and 2 or 0
end

-- Highest-priority sign per buffer row (0-based) in [top, bot], ready to draw.
-- shortcut: one sign per line even with a wider column; extra signs are not shown.
local function collect_signs(top, bot)
  local by_row = {}
  local marks = api.nvim_buf_get_extmarks(0, -1, { top - 1, 0 }, { bot - 1, -1 }, { details = true, type = 'sign' })
  for _, m in ipairs(marks) do
    local d = m[4]
    local cur = by_row[m[2]]
    if not cur or (d.priority or 0) > cur.priority or ((d.priority or 0) == cur.priority and m[1] > cur.id) then
      by_row[m[2]] = { id = m[1], priority = d.priority or 0, text = d.sign_text, hl = d.sign_hl_group }
    end
  end
  return by_row
end

-- 'eol' virtual text per buffer row (0-based) in [top, bot], in extmark order.
-- shortcut: only virt_text_pos 'eol'; overlay/right_align/inline are not drawn.
local function collect_virt_text(top, bot)
  local by_row = {}
  local marks = api.nvim_buf_get_extmarks(0, -1, { top - 1, 0 }, { bot - 1, -1 }, { details = true, type = 'virt_text' })
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.virt_text and (d.virt_text_pos or 'eol') == 'eol' then
      local row = by_row[m[2]] or {}
      by_row[m[2]] = row
      for _, chunk in ipairs(d.virt_text) do
        local hl = chunk[2]
        row[#row + 1] = { chunk[1], type(hl) == 'table' and hl[#hl] or hl }
      end
    end
  end
  return by_row
end

local attr_codes = { bold = '1', italic = '3', underline = '4', undercurl = '4:3', strikethrough = '9', reverse = '7' }

local function hl_escape(name)
  if not name or name == 0 then
    return ''
  end
  local hl = vim._hl_resolve(name)
  if not hl then
    return ''
  end
  local esc = ''
  -- without 'termguicolors' Neovim draws the cterm attributes and 16/256-color numbers
  local gui = vim.o.termguicolors
  local attrs = gui and hl or (hl.cterm or {})
  for attr, code in pairs(attr_codes) do
    if attrs[attr] then
      esc = esc .. '\27[' .. code .. 'm'
    end
  end
  if not gui then
    local function cterm(n, base)
      if n < 8 then
        return '\27[' .. (base + n) .. 'm'
      elseif n < 16 then
        return '\27[' .. (base + 60 + n - 8) .. 'm'
      end
      return '\27[' .. (base + 8) .. ';5;' .. n .. 'm'
    end
    if hl.ctermfg then
      esc = esc .. cterm(hl.ctermfg, 30)
    end
    if hl.ctermbg then
      esc = esc .. cterm(hl.ctermbg, 40)
    end
    return esc
  end
  if hl.fg then
    esc = esc .. string.format('\27[38;2;%d;%d;%dm', math.floor(hl.fg / 65536) % 256, math.floor(hl.fg / 256) % 256, hl.fg % 256)
  end
  if hl.bg then
    esc = esc .. string.format('\27[48;2;%d;%d;%dm', math.floor(hl.bg / 65536) % 256, math.floor(hl.bg / 256) % 256, hl.bg % 256)
  end
  return esc
end

-- Per visible row (0-based): byte -> escape of the winning highlight (higher priority wins,
-- later marks win ties), from 'hl_group' extmarks and this redraw's ephemeral marks.
-- shortcut: no blending of fg/bg between overlapping groups; the winner's group is drawn alone.
local function collect_highlights(top, bot, lines)
  local marks = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(0, -1, { top - 1, 0 }, { bot - 1, -1 }, { details = true, type = 'highlight', overlap = true })) do
    local d = m[4]
    marks[#marks + 1] = { row = m[2], col = m[3], end_row = d.end_row or m[2], end_col = d.end_col or m[3], hl_group = d.hl_group, priority = d.priority or 4096 }
  end
  for _, m in ipairs(S.ephemeral) do
    if m.hl_group then
      marks[#marks + 1] = m
    end
  end
  if #marks == 0 then
    return {}
  end
  local cache, by_row, prio = {}, {}, {}
  for _, m in ipairs(marks) do
    local esc = cache[m.hl_group]
    if not esc then
      esc = hl_escape(m.hl_group)
      cache[m.hl_group] = esc
    end
    if esc ~= '' then
      for row = math.max(m.row, top - 1), math.min(m.end_row, bot - 1) do
        local line = lines[row - top + 2] or ''
        local from = row == m.row and m.col or 0
        local to = row == m.end_row and m.end_col or #line
        local map, pr = by_row[row], prio[row]
        if not map then
          map, pr = {}, {}
          by_row[row], prio[row] = map, pr
        end
        for b = from, math.min(to, #line) - 1 do
          if not pr[b] or m.priority >= pr[b] then
            map[b], pr[b] = esc, m.priority
          end
        end
      end
    end
  end
  return by_row
end

local function draw()
  local rows, cols = vim._tty_size()
  S.rows, S.cols = rows, cols
  local n = nlines()
  local textrows = math.max(1, rows - 2)
  local number, rnu = vim.o.number, vim.o.relativenumber
  local gw = 0
  if number or rnu then
    gw = math.max(3, #tostring(n)) + 1
  end
  local sw = sign_width()
  local textcols = math.max(1, cols - sw - gw)

  clamp()
  local so = vim.o.scrolloff
  if type(so) ~= 'number' then
    so = 0
  end
  so = math.min(so, math.floor((textrows - 1) / 2))
  if S.row < S.top + so then
    S.top = math.max(1, S.row - so)
  elseif S.row > S.top + textrows - 1 - so then
    S.top = S.row - (textrows - 1 - so)
  end
  if S.top > n then
    S.top = n
  end
  if S.top < 1 then
    S.top = 1
  end

  local cline = getline(S.row)
  local dc = display_col(cline, S.col, S.mode ~= 'i')
  if dc < S.left then
    S.left = dc
  elseif dc >= S.left + textcols then
    S.left = dc - textcols + 1
  end
  if S.left < 0 then
    S.left = 0
  end

  local lines = api.nvim_buf_get_lines(0, S.top - 1, S.top - 1 + textrows, false)
  local bot = math.min(n, S.top + textrows - 1)
  pcall(api.nvim_win_set_cursor, 0, { S.row, S.col })
  S.ephemeral = {}
  run_decoration_providers(S.top, bot)
  if sw == 0 then
    sw = sign_width() -- providers may have placed the first sign ('signcolumn' auto)
    textcols = math.max(1, cols - sw - gw)
  end
  local signs = sw > 0 and collect_signs(S.top, bot) or {}
  local vtext = collect_virt_text(S.top, bot)
  local hls = collect_highlights(S.top, bot, lines)
  local vr1, vc1, vr2, vc2
  if S.mode == 'v' or S.mode == 'V' then
    vr1, vc1, vr2, vc2 = visual_bounds()
  end

  local out = { '\27[?25l' }
  for r = 0, textrows - 1 do
    local lnum = S.top + r
    out[#out + 1] = string.format('\27[%d;1H', r + 1)
    local text = lines[r + 1]
    if text and lnum <= n then
      if sw > 0 then
        local sign = signs[lnum - 1]
        if sign and sign.text then
          local stext = sign.text .. (' '):rep(math.max(0, sw - str_width(sign.text)))
          out[#out + 1] = hl_escape(sign.hl) .. stext .. '\27[0m'
        else
          out[#out + 1] = (' '):rep(sw)
        end
      end
      if gw > 0 then
        local label
        local current = lnum == S.row
        if rnu then
          if current then
            label = number and string.format('%-' .. (gw - 1) .. 'd ', lnum) or string.format('%' .. (gw - 1) .. 'd ', 0)
          else
            label = string.format('%' .. (gw - 1) .. 'd ', math.abs(lnum - S.row))
          end
        else
          label = string.format('%' .. (gw - 1) .. 'd ', lnum)
        end
        out[#out + 1] = (current and '\27[38;5;178m' or '\27[38;5;240m') .. label .. '\27[0m'
      end
      local selfn
      if vr1 and lnum >= vr1 and lnum <= vr2 then
        if S.mode == 'V' then
          selfn = function()
            return true
          end
        else
          selfn = function(b)
            if lnum == vr1 and b < vc1 then
              return false
            end
            if lnum == vr2 and b > vc2 then
              return false
            end
            return true
          end
        end
      end
      out[#out + 1] = render_line(text, S.left, textcols, selfn, hls[lnum - 1])
      local vt = vtext[lnum - 1]
      if vt then
        local _, total = cells(text)
        local room = textcols - math.max(0, total - S.left) - 1
        if room > 0 then
          out[#out + 1] = ' '
          for _, chunk in ipairs(vt) do
            if room <= 0 then
              break
            end
            local t = truncate(chunk[1], room)
            room = room - str_width(t)
            out[#out + 1] = hl_escape(chunk[2]) .. t .. '\27[0m'
          end
        end
      end
    else
      out[#out + 1] = '\27[38;5;240m~\27[0m'
    end
    out[#out + 1] = '\27[K'
  end

  -- status line
  local name = vim._buf_short_name(0)
  if name == '' then
    name = '[No Name]'
  end
  local modified = vim._buf_modified(0)
  local left_text = ' ' .. mode_name() .. '  ' .. name .. (modified and ' [+]' or '')
  local pct = n <= 1 and 100 or math.floor((S.row - 1) * 100 / (n - 1))
  local right_text = string.format('%d:%d  %d%% ', S.row, dc + 1, pct)
  local pad = cols - str_width(left_text) - str_width(right_text)
  if pad < 1 then
    left_text = truncate(left_text, math.max(0, cols - str_width(right_text) - 1))
    pad = math.max(1, cols - str_width(left_text) - str_width(right_text))
  end
  out[#out + 1] = string.format('\27[%d;1H\27[7m%s%s%s\27[0m', rows - 1, left_text, (' '):rep(pad), right_text)

  -- command / message line
  local bottom
  if S.cmdtype then
    bottom = S.cmdtype .. S.cmdtext
  elseif S.msg ~= '' then
    bottom = S.msg
  elseif S.mode == 'i' then
    bottom = '-- INSERT --'
  elseif S.mode == 'v' then
    bottom = '-- VISUAL --'
  elseif S.mode == 'V' then
    bottom = '-- VISUAL LINE --'
  else
    bottom = ''
  end
  bottom = truncate(bottom, cols - 1)
  out[#out + 1] = string.format('\27[%d;1H', rows)
  if S.msg_err and not S.cmdtype and S.msg ~= '' then
    out[#out + 1] = '\27[97;41m' .. bottom .. '\27[0m'
  else
    out[#out + 1] = bottom
  end
  out[#out + 1] = '\27[K'

  -- cursor
  local shape = S.mode == 'i' and '\27[6 q' or '\27[2 q'
  if shape ~= S.shape then
    out[#out + 1] = shape
    S.shape = shape
  end
  if S.cmdtype then
    out[#out + 1] = string.format('\27[%d;%dH', rows, str_width(bottom) + 1)
  else
    S.screen_row, S.screen_col = S.row - S.top + 1, sw + gw + (dc - S.left) + 1
    out[#out + 1] = string.format('\27[%d;%dH', S.screen_row, S.screen_col)
  end
  out[#out + 1] = '\27[?25h'
  write(table.concat(out))

  pcall(api.nvim_win_set_cursor, 0, { S.row, S.col })
  S.drawn_gen = vim._ui_gen
end

-- -------------------------------------------------------------------- input

local CSI = {
  A = '<Up>',
  B = '<Down>',
  C = '<Right>',
  D = '<Left>',
  H = '<Home>',
  F = '<End>',
}
local CSI_TILDE = {
  ['1'] = '<Home>',
  ['7'] = '<Home>',
  ['4'] = '<End>',
  ['8'] = '<End>',
  ['3'] = '<Del>',
  ['5'] = '<PageUp>',
  ['6'] = '<PageDown>',
}

local function control_key(b)
  if b == 13 or b == 10 then
    return '<CR>'
  elseif b == 9 then
    return '<Tab>'
  elseif b == 8 or b == 127 then
    return '<BS>'
  elseif b == 27 then
    return '<Esc>'
  elseif b >= 1 and b <= 26 then
    return '<C-' .. string.char(b + 96) .. '>'
  end
  return nil
end

-- Turn raw bytes into key names appended to S.queue. Returns false when the
-- tail of the buffer is an incomplete sequence that needs more bytes.
local function parse_input(final)
  local s = S.rbuf
  local i = 1
  local n = #s
  while i <= n do
    local b = s:byte(i)
    if b == 27 then
      local nx = s:sub(i + 1, i + 1)
      if nx == '[' or nx == 'O' then
        local params, final_ch = s:match('^[%[O]([%d;]*)([%a~])', i + 1)
        if params then
          local len = 2 + #params + 1
          local key
          if final_ch == '~' then
            key = CSI_TILDE[params:match('^(%d+)')]
          else
            key = CSI[final_ch]
          end
          S.queue[#S.queue + 1] = key or '<Nop>'
          i = i + len
        elseif final then
          S.queue[#S.queue + 1] = '<Esc>'
          i = i + 1
        else
          S.rbuf = s:sub(i)
          return false
        end
      elseif nx == '' then
        if final then
          S.queue[#S.queue + 1] = '<Esc>'
          i = i + 1
        else
          S.rbuf = s:sub(i)
          return false
        end
      else
        S.queue[#S.queue + 1] = '<Esc>'
        i = i + 1
      end
    elseif b < 32 or b == 127 then
      S.queue[#S.queue + 1] = control_key(b) or '<Nop>'
      i = i + 1
    elseif b < 0x80 then
      S.queue[#S.queue + 1] = string.char(b)
      i = i + 1
    else
      local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
      if i + len - 1 > n then
        if final then
          i = n + 1
        else
          S.rbuf = s:sub(i)
          return false
        end
      else
        S.queue[#S.queue + 1] = s:sub(i, i + len - 1)
        i = i + len
      end
    end
  end
  S.rbuf = ''
  return true
end

local function getkey()
  local k = table.remove(S.inject, 1)
  S.from_inject = k ~= nil
  k = k or table.remove(S.queue, 1)
  if not k and S.in_normal then
    return '<Esc>'
  end
  if not k then
    draw()
    local last_size = S.rows * 1000 + S.cols
    while not k and not S.quit do
      local data = vim._tty_read(100)
      if data == nil then
        S.quit = true
        return '<Esc>'
      end
      if data ~= '' then
        S.rbuf = S.rbuf .. data
        if not parse_input(false) then
          -- incomplete escape sequence or multi-byte char: wait briefly
          local more = vim._tty_read(25)
          if more == nil then
            S.quit = true
            return '<Esc>'
          end
          S.rbuf = S.rbuf .. more
          parse_input(true)
        end
      else
        local rows, cols = vim._tty_size()
        if rows * 1000 + cols ~= last_size or vim._ui_gen ~= S.drawn_gen then
          draw() -- resized, or async work (e.g. gitsigns) changed what is shown
          last_size = rows * 1000 + cols
        end
      end
      k = table.remove(S.queue, 1)
    end
    if not k then
      return '<Esc>'
    end
  end
  if not S.from_inject then
    S.msg = '' -- keep an error shown by a failed mapping while its fallback keys run
    S.msg_err = false
  end
  S.cur_keys[#S.cur_keys + 1] = k
  return k
end

-- Raw key bytes (what nvim_replace_termcodes returns) -> TUI key tokens.
-- shortcut: only <C-x>, arrows/Home/End/PageUp/PageDown/Del/BS and <Plug>(name)
-- survive; other modifiers and special keys are dropped.
local RAW_SPECIAL = {
  ku = '<Up>', kd = '<Down>', kl = '<Left>', kr = '<Right>', kb = '<BS>', kD = '<Del>',
  kh = '<Home>', ['@7'] = '<End>', kP = '<PageUp>', kN = '<PageDown>',
}

local function raw_to_tokens(raw)
  local out, i, n = {}, 1, #raw
  while i <= n do
    local b = raw:byte(i)
    if b == 0x80 and i + 2 <= n then
      local b2, b3 = raw:byte(i + 1), raw:byte(i + 2)
      if b2 == 0xfd and b3 == 0x53 then
        local name = raw:match('^%b()', i + 3) or ''
        out[#out + 1] = '<Plug>' .. name
        i = i + 3 + #name
      elseif b2 == 0xfd then
        i = i + 3 -- <Ignore> and other extras type nothing
      elseif b2 == 0xfc then
        local nxt = raw:sub(i + 3, i + 3)
        if b3 == 0x04 and nxt:match('^%a$') then
          out[#out + 1] = '<C-' .. nxt:lower() .. '>'
        end
        i = i + 4
      else
        out[#out + 1] = RAW_SPECIAL[string.char(b2, b3)]
        i = i + 3
      end
    elseif b < 32 or b == 127 then
      out[#out + 1] = control_key(b) or '<Nop>'
      i = i + 1
    else
      local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
      out[#out + 1] = raw:sub(i, i + len - 1)
      i = i + len
    end
  end
  return out
end

-- nvim_feedkeys: 'i' inserts before pending input, 'n' means do not remap.
vim._tui_feed = function(raw, mode)
  local tokens = raw_to_tokens(raw)
  local target = mode:find('n', 1, true) and S.inject or S.queue
  if mode:find('i', 1, true) then
    for j = #tokens, 1, -1 do
      table.insert(target, 1, tokens[j])
    end
  else
    for _, tok in ipairs(tokens) do
      target[#target + 1] = tok
    end
  end
end

-- Implemented after ex() because mappings may run Ex commands.
local map_key
local function getkey_cmd(depth)
  return map_key(getkey(), depth or 0)
end

local function queue_front(keys)
  for i = #keys, 1, -1 do
    table.insert(S.queue, 1, keys[i])
  end
end

-- ----------------------------------------------------------------- motions

local function char_class(s, i, big)
  local cp = decode(s, i)
  if not cp or cp == 32 or cp == 9 or cp == 0 or cp == 0xA0 then
    return 0
  end
  if big then
    return 1
  end
  if (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) or cp == 95 then
    return 1
  end
  if cp >= 0x80 then
    if (cp >= 0x2000 and cp <= 0x2BFF) or (cp >= 0x3000 and cp <= 0x303F) or (cp >= 0xFF00 and cp <= 0xFF0F) then
      return 2
    end
    return 1
  end
  return 2
end

local function motion_w(row, col, big)
  local n = nlines()
  local line = getline(row)
  if #line > 0 then
    local cls = char_class(line, col + 1, big)
    if cls ~= 0 then
      while col < #line and char_class(line, col + 1, big) == cls do
        col = next_col(line, col)
      end
    end
  end
  while true do
    if col >= #line then
      if row >= n then
        return row, #line
      end
      row = row + 1
      line = getline(row)
      col = 0
      if #line == 0 then
        return row, 0
      end
    elseif char_class(line, col + 1, big) == 0 then
      col = next_col(line, col)
    else
      return row, col
    end
  end
end

local function motion_e(row, col, big)
  local n = nlines()
  local line = getline(row)
  if col < #line then
    col = next_col(line, col)
  end
  while true do
    if col >= #line then
      if row >= n then
        return row, last_col(line)
      end
      row = row + 1
      line = getline(row)
      col = 0
    elseif char_class(line, col + 1, big) == 0 then
      col = next_col(line, col)
    else
      break
    end
  end
  local cls = char_class(line, col + 1, big)
  while true do
    local nx = next_col(line, col)
    if nx < #line and char_class(line, nx + 1, big) == cls then
      col = nx
    else
      break
    end
  end
  return row, col
end

local function motion_b(row, col, big)
  local line = getline(row)
  while true do
    if col <= 0 then
      if row <= 1 then
        return 1, 0
      end
      row = row - 1
      line = getline(row)
      if #line == 0 then
        return row, 0
      end
      col = last_col(line)
    else
      col = prev_col(line, col)
    end
    if char_class(line, col + 1, big) ~= 0 then
      break
    end
  end
  local cls = char_class(line, col + 1, big)
  while col > 0 do
    local p = prev_col(line, col)
    if char_class(line, p + 1, big) == cls then
      col = p
    else
      break
    end
  end
  return row, col
end

-- End of the word under the cursor (for `cw`).
local function word_end_here(line, col, big)
  local cls = char_class(line, col + 1, big)
  while true do
    local nx = next_col(line, col)
    if nx < #line and char_class(line, nx + 1, big) == cls then
      col = nx
    else
      break
    end
  end
  return col
end

local function find_char(kind, ch, count, row, col, op)
  local line = getline(row)
  local pos = col
  for _ = 1, count do
    if kind == 'f' or kind == 't' then
      local from = next_col(line, pos)
      if kind == 't' and S.find_repeat then
        from = next_col(line, from)
      end
      local idx = line:find(ch, from + 1, true)
      if not idx then
        return nil
      end
      pos = idx - 1
    else
      local found
      local limit = pos
      if kind == 'T' and S.find_repeat then
        limit = prev_col(line, limit)
      end
      local startp = 1
      while true do
        local idx = line:find(ch, startp, true)
        if not idx or idx - 1 >= limit then
          break
        end
        found = idx - 1
        startp = idx + 1
      end
      if not found then
        return nil
      end
      pos = found
    end
  end
  if kind == 't' then
    pos = prev_col(line, pos)
  elseif kind == 'T' then
    pos = next_col(line, pos)
  end
  return pos
end

local PAIRS = { ['('] = ')', ['['] = ']', ['{'] = '}', [')'] = '(', [']'] = '[', ['}'] = '{' }

local function match_bracket(row, col)
  local line = getline(row)
  local i = line:find('[%(%)%[%]{}]', col + 1)
  if not i then
    return nil
  end
  local ch = line:sub(i, i)
  local other = PAIRS[ch]
  local forward = ch == '(' or ch == '[' or ch == '{'
  local depth = 0
  local r = row
  local pos = i
  local n = nlines()
  local text = line
  while true do
    local c = text:sub(pos, pos)
    if c == ch then
      depth = depth + 1
    elseif c == other then
      depth = depth - 1
      if depth == 0 then
        return r, pos - 1
      end
    end
    if forward then
      pos = pos + 1
      if pos > #text then
        r = r + 1
        if r > n then
          return nil
        end
        text = getline(r)
        pos = 1
        if #text == 0 then
          pos = 1
        end
      end
    else
      pos = pos - 1
      if pos < 1 then
        r = r - 1
        if r < 1 then
          return nil
        end
        text = getline(r)
        pos = #text
      end
    end
  end
end

local function search_text(pat, dir, from_row, from_col)
  local n = nlines()
  local ic = vim.o.ignorecase and not (vim.o.smartcase and pat:find('%u'))
  local p = ic and pat:lower() or pat
  for step = 0, n do
    local r = ((from_row - 1 + (dir > 0 and step or -step)) % n) + 1
    local line = getline(r)
    local hay = ic and line:lower() or line
    if dir > 0 then
      local init = 1
      if step == 0 then
        init = next_col(line, from_col) + 1
        if from_col >= #line then
          init = #line + 2
        end
      end
      local s = hay:find(p, init, true)
      if s then
        return r, s - 1
      end
    else
      local limit = (step == 0) and from_col or math.huge
      local found
      local startp = 1
      while true do
        local s = hay:find(p, startp, true)
        if not s or s - 1 >= limit then
          break
        end
        found = s - 1
        startp = s + 1
      end
      if found then
        return r, found
      end
    end
  end
  return nil
end

local function do_search(dir, count)
  if not S.search then
    err('E35: No previous regular expression')
    return nil
  end
  local row, col = S.row, S.col
  local r, c
  for _ = 1, count or 1 do
    r, c = search_text(S.search.pat, dir, row, col)
    if not r then
      err('E486: Pattern not found: ' .. S.search.pat)
      return nil
    end
    row, col = r, c
  end
  return r, c
end

local function word_under_cursor()
  local line = getline(S.row)
  if #line == 0 then
    return nil
  end
  local col = S.col
  if char_class(line, col + 1, false) == 0 then
    local i = line:find('[^ \t]', col + 1)
    if not i then
      return nil
    end
    col = i - 1
  end
  local cls = char_class(line, col + 1, false)
  local s = col
  while s > 0 do
    local p = prev_col(line, s)
    if char_class(line, p + 1, false) == cls then
      s = p
    else
      break
    end
  end
  local e = word_end_here(line, col, false)
  return line:sub(s + 1, next_col(line, e)), s
end

-- Returns row, col, kind ('excl' | 'incl' | 'line'), keep_want. nil = motion failed.
local function do_motion(k, count, op)
  local c1 = count or 1
  local n = nlines()
  local row, col = S.row, S.col
  local line = getline(row)
  if k == 'h' or k == '<Left>' or k == '<BS>' then
    local start = col
    for _ = 1, c1 do
      col = prev_col(line, col)
    end
    if col == start and not op then
      return nil
    end
    return row, col, 'excl'
  elseif k == 'l' or k == '<Right>' or k == ' ' then
    for _ = 1, c1 do
      local nx = next_col(line, col)
      if op then
        col = nx
      elseif nx >= #line then
        break
      else
        col = nx
      end
    end
    return row, col, 'excl'
  elseif k == '0' or k == '<Home>' then
    return row, 0, 'excl'
  elseif k == '^' then
    return row, first_nonblank(line), 'excl'
  elseif k == '$' or k == '<End>' then
    row = math.min(n, row + c1 - 1)
    S.want = math.huge
    return row, last_col(getline(row)), 'incl', true
  elseif k == '_' then
    row = math.min(n, row + c1 - 1)
    return row, first_nonblank(getline(row)), 'line'
  elseif k == 'j' or k == '<Down>' or k == '<C-n>' or k == '<C-j>' or k == '+' then
    if row >= n then
      return nil
    end
    row = math.min(n, row + c1)
    S.want = S.want or cur_dcol()
    local l = getline(row)
    if k == '+' then
      return row, first_nonblank(l), 'line'
    end
    return row, S.want == math.huge and last_col(l) or col_for_display(l, S.want, false), 'line', true
  elseif k == 'k' or k == '<Up>' or k == '<C-p>' or k == '-' then
    if row <= 1 then
      return nil
    end
    row = math.max(1, row - c1)
    S.want = S.want or cur_dcol()
    local l = getline(row)
    if k == '-' then
      return row, first_nonblank(l), 'line'
    end
    return row, S.want == math.huge and last_col(l) or col_for_display(l, S.want, false), 'line', true
  elseif k == 'w' or k == 'W' then
    local big = k == 'W'
    for _ = 1, c1 do
      row, col = motion_w(row, col, big)
    end
    return row, col, 'excl'
  elseif k == 'e' or k == 'E' then
    local big = k == 'E'
    for _ = 1, c1 do
      row, col = motion_e(row, col, big)
    end
    return row, col, 'incl'
  elseif k == 'b' or k == 'B' then
    local big = k == 'B'
    for _ = 1, c1 do
      row, col = motion_b(row, col, big)
    end
    return row, col, 'excl'
  elseif k == 'G' then
    row = count and math.min(n, count) or n
    return row, first_nonblank(getline(row)), 'line'
  elseif k == 'g' then
    local k2 = getkey()
    if k2 == 'g' then
      row = count and math.min(n, count) or 1
      return row, first_nonblank(getline(row)), 'line'
    elseif k2 == 'e' or k2 == 'E' then
      -- backward to end of word: approximate with b then end of that word
      local r2, c2 = motion_b(row, col, k2 == 'E')
      if r2 == row and c2 == col then
        return nil
      end
      local l2 = getline(r2)
      return r2, word_end_here(l2, c2, k2 == 'E'), 'incl'
    elseif k2 == '_' then
      row = math.min(n, row + c1 - 1)
      local l = getline(row)
      local e = l:find('[^ \t][ \t]*$')
      return row, e and prev_col(l, e) + 0 or 0, 'incl'
    elseif k2 == 'j' or k2 == 'k' then
      return do_motion(k2, count, op)
    end
    return nil
  elseif k == 'f' or k == 't' or k == 'F' or k == 'T' then
    local ch = getkey()
    if is_special(ch) then
      return nil
    end
    S.find = { kind = k, ch = ch }
    local pos = find_char(k, ch, c1, row, col, op)
    if not pos then
      return nil
    end
    return row, pos, (k == 'f' or k == 't') and 'incl' or 'excl'
  elseif k == ';' or k == ',' then
    if not S.find then
      return nil
    end
    local kind = S.find.kind
    if k == ',' then
      kind = ({ f = 'F', F = 'f', t = 'T', T = 't' })[kind]
    end
    S.find_repeat = true
    local pos = find_char(kind, S.find.ch, c1, row, col, op)
    S.find_repeat = false
    if not pos then
      return nil
    end
    return row, pos, (kind == 'f' or kind == 't') and 'incl' or 'excl'
  elseif k == '%' then
    local r, c = match_bracket(row, col)
    if not r then
      return nil
    end
    return r, c, 'incl'
  elseif k == '}' then
    local r = row
    while r < n and #getline(r) == 0 do
      r = r + 1
    end
    while r < n and #getline(r) > 0 do
      r = r + 1
    end
    return r, #getline(r) == 0 and 0 or last_col(getline(r)), 'excl'
  elseif k == '{' then
    local r = row
    while r > 1 and #getline(r) == 0 do
      r = r - 1
    end
    while r > 1 and #getline(r) > 0 do
      r = r - 1
    end
    return r, 0, 'excl'
  elseif k == 'H' then
    row = math.min(n, S.top + (count and count - 1 or 0))
    return row, first_nonblank(getline(row)), 'line'
  elseif k == 'L' then
    row = math.min(n, S.top + (S.rows - 2) - 1 - (count and count - 1 or 0))
    return row, first_nonblank(getline(row)), 'line'
  elseif k == 'M' then
    row = math.min(n, S.top + math.floor((math.min(S.rows - 2, n - S.top + 1) - 1) / 2))
    return row, first_nonblank(getline(row)), 'line'
  elseif k == 'n' or k == 'N' then
    local dir = S.search and S.search.dir or 1
    if k == 'N' then
      dir = -dir
    end
    local r, c = do_search(dir, c1)
    if not r then
      return nil
    end
    return r, c, 'excl'
  elseif k == '*' or k == '#' then
    local word = word_under_cursor()
    if not word then
      err('E348: No string under cursor')
      return nil
    end
    S.search = { pat = word, dir = k == '*' and 1 or -1 }
    local r, c = do_search(S.search.dir, c1)
    if not r then
      return nil
    end
    return r, c, 'excl'
  end
  return false
end

-- ----------------------------------------------------------------- regions

local function ordered_region(r1, c1, r2, c2, kind)
  if kind == 'line' then
    return { sr = math.min(r1, r2), er = math.max(r1, r2), sc = 0, ec = 0, linewise = true }
  end
  local sr, sc, er, ec = r1, c1, r2, c2
  if r2 < r1 or (r2 == r1 and c2 < c1) then
    sr, sc, er, ec = r2, c2, r1, c1
  end
  local eline = getline(er)
  if kind == 'incl' then
    ec = next_col(eline, ec)
  elseif ec == 0 and er > sr then
    -- exclusive motion ending in column 0: stop at the end of the previous line
    er = er - 1
    ec = #getline(er)
  end
  return { sr = sr, sc = sc, er = er, ec = ec, linewise = false }
end

local function region_text(r)
  if r.linewise then
    return api.nvim_buf_get_lines(0, r.sr - 1, r.er, false)
  end
  if r.sr == r.er then
    return { getline(r.sr):sub(r.sc + 1, r.ec) }
  end
  local out = { getline(r.sr):sub(r.sc + 1) }
  for i = r.sr + 1, r.er - 1 do
    out[#out + 1] = getline(i)
  end
  out[#out + 1] = getline(r.er):sub(1, r.ec)
  return out
end

local function delete_region(r)
  if r.linewise then
    replace_lines(r.sr - 1, r.er, {})
    local row = math.min(r.sr, nlines())
    set_cursor(row, first_nonblank(getline(row)))
  else
    local first = getline(r.sr)
    local last = getline(r.er)
    replace_lines(r.sr - 1, r.er, { first:sub(1, r.sc) .. last:sub(r.ec + 1) })
    set_cursor(r.sr, r.sc)
  end
end

local function indent_unit()
  local sw = vim.o.shiftwidth
  if type(sw) ~= 'number' or sw <= 0 then
    sw = vim.o.tabstop
  end
  if vim.o.expandtab then
    return (' '):rep(sw), sw
  end
  return '\t', sw
end

local function shift_lines(first, last, dir, times)
  local unit, sw = indent_unit()
  local lines = api.nvim_buf_get_lines(0, first - 1, last, false)
  for i, l in ipairs(lines) do
    for _ = 1, times do
      if dir > 0 then
        if l ~= '' then
          l = unit .. l
        end
      else
        if l:sub(1, 1) == '\t' then
          l = l:sub(2)
        else
          local sp = l:match('^( *)')
          l = l:sub(math.min(#sp, sw) + 1)
        end
      end
    end
    lines[i] = l
  end
  replace_lines(first - 1, last, lines)
  set_cursor(first, first_nonblank(getline(first)))
end

local insert_mode

-- Yanks/deletes go to the named register (or the 'clipboard' default) and "; yanks also to 0.
local function reg_write(r, yank)
  local text, lw = region_text(r), r.linewise
  local name = S.pending_reg or vim._reg_default()
  vim._reg_set(name, text, lw)
  vim._reg_set('"', text, lw)
  if yank and name == vim._reg_default() then
    vim._reg_set('0', text, lw)
  end
end

local function reg_read()
  return vim._reg_get(S.pending_reg or vim._reg_default()) or vim._reg_get('"')
    or { text = { '' }, linewise = false }
end

local function apply_op(op, r)
  if op == 'y' then
    reg_write(r, true)
    if r.linewise then
      set_cursor(r.sr, S.row == r.sr and S.col or 0, true)
      local cnt = r.er - r.sr + 1
      if cnt > 2 then
        info(cnt .. ' lines yanked')
      end
    else
      set_cursor(r.sr, r.sc)
    end
  elseif op == 'd' then
    reg_write(r)
    delete_region(r)
    S.changed = true
    local cnt = r.er - r.sr + 1
    if r.linewise and cnt > 2 then
      info(cnt .. ' fewer lines')
    end
  elseif op == 'c' then
    reg_write(r)
    S.changed = true
    if r.linewise then
      local indent = ''
      if vim.o.autoindent then
        indent = getline(r.sr):match('^[ \t]*') or ''
      end
      replace_lines(r.sr - 1, r.er, { indent })
      S.mode = 'i'
      set_cursor(r.sr, #indent)
    else
      local first = getline(r.sr)
      local last = getline(r.er)
      replace_lines(r.sr - 1, r.er, { first:sub(1, r.sc) .. last:sub(r.ec + 1) })
      S.mode = 'i'
      set_cursor(r.sr, r.sc)
    end
    insert_mode()
  elseif op == '>' or op == '<' then
    shift_lines(r.sr, r.er, op == '>' and 1 or -1, 1)
    S.changed = true
  end
end

-- Text objects: iw aw i" a" i( a( ...
local function text_object(kind, key)
  local inner = kind == 'i'
  local line = getline(S.row)
  if key == 'w' or key == 'W' then
    if #line == 0 then
      return nil
    end
    local big = key == 'W'
    local col = S.col
    local cls = char_class(line, col + 1, big)
    local s = col
    while s > 0 do
      local p = prev_col(line, s)
      if char_class(line, p + 1, big) == cls then
        s = p
      else
        break
      end
    end
    local e = word_end_here(line, col, big)
    local ecx = next_col(line, e)
    if not inner then
      if ecx < #line and char_class(line, ecx + 1, big) == 0 and cls ~= 0 then
        while ecx < #line and char_class(line, ecx + 1, big) == 0 do
          ecx = next_col(line, ecx)
        end
      elseif cls ~= 0 then
        while s > 0 do
          local p = prev_col(line, s)
          if char_class(line, p + 1, big) == 0 then
            s = p
          else
            break
          end
        end
      end
    end
    return { sr = S.row, sc = s, er = S.row, ec = ecx, linewise = false }
  elseif key == '"' or key == "'" or key == '`' then
    local positions = {}
    local i = 1
    while true do
      local p = line:find(key, i, true)
      if not p then
        break
      end
      if p == 1 or line:sub(p - 1, p - 1) ~= '\\' then
        positions[#positions + 1] = p - 1
      end
      i = p + 1
    end
    for idx = 1, #positions - 1, 2 do
      local a, b = positions[idx], positions[idx + 1]
      if S.col <= b and (S.col >= a or idx == 1 or true) and b >= S.col then
        if S.col >= a or true then
          if inner then
            return { sr = S.row, sc = a + 1, er = S.row, ec = b, linewise = false }
          end
          return { sr = S.row, sc = a, er = S.row, ec = b + 1, linewise = false }
        end
      end
    end
    return nil
  else
    local open, close
    if key == '(' or key == ')' or key == 'b' then
      open, close = '(', ')'
    elseif key == '[' or key == ']' then
      open, close = '[', ']'
    elseif key == '{' or key == '}' or key == 'B' then
      open, close = '{', '}'
    elseif key == '<' or key == '>' then
      open, close = '<', '>'
    else
      return nil
    end
    local n = nlines()
    -- search backwards for the unmatched opener
    local r, pos = S.row, S.col + 1
    local text = line
    local depth = 0
    local orow, ocol
    if text:sub(pos, pos) == open then
      orow, ocol = r, pos - 1
    else
      if text:sub(pos, pos) == close then
        depth = 0
      end
      while true do
        pos = pos - 1
        if pos < 1 then
          r = r - 1
          if r < 1 or S.row - r > 500 then
            return nil
          end
          text = getline(r)
          pos = #text
        end
        local ch = text:sub(pos, pos)
        if ch == close and not (r == S.row and pos == S.col + 1) then
          depth = depth + 1
        elseif ch == open then
          if depth == 0 then
            orow, ocol = r, pos - 1
            break
          end
          depth = depth - 1
        end
        if r == 1 and pos <= 1 then
          return nil
        end
      end
    end
    -- forward for the matching closer
    local cr, cpos = orow, ocol + 1
    text = getline(cr)
    depth = 0
    local crow, ccol
    while true do
      local ch = text:sub(cpos, cpos)
      if ch == open then
        depth = depth + 1
      elseif ch == close then
        depth = depth - 1
        if depth == 0 then
          crow, ccol = cr, cpos - 1
          break
        end
      end
      cpos = cpos + 1
      if cpos > #text then
        cr = cr + 1
        if cr > n or cr - orow > 500 then
          return nil
        end
        text = getline(cr)
        cpos = 1
      end
    end
    if inner then
      return { sr = orow, sc = ocol + 1, er = crow, ec = ccol, linewise = false }
    end
    return { sr = orow, sc = ocol, er = crow, ec = ccol + 1, linewise = false }
  end
end

local function run_operator(op, k2, count, c2)
  local total = (count or 1) * (c2 or 1)
  local has_count = count or c2
  local n = nlines()
  local region
  if k2 == op then
    local er = math.min(n, S.row + total - 1)
    region = { sr = S.row, er = er, sc = 0, ec = 0, linewise = true }
  elseif k2 == 'i' or k2 == 'a' then
    local key = getkey()
    region = text_object(k2, key)
    if not region then
      return
    end
  else
    if op == 'c' and (k2 == 'w' or k2 == 'W') then
      local line = getline(S.row)
      if #line > 0 and char_class(line, S.col + 1, k2 == 'W') ~= 0 then
        -- `cw` behaves like `ce` on a word
        local row, col = S.row, S.col
        for i = 1, total do
          if i == 1 then
            col = word_end_here(getline(row), col, k2 == 'W')
          else
            row, col = motion_e(row, col, k2 == 'W')
          end
        end
        region = ordered_region(S.row, S.col, row, col, 'incl')
      end
    end
    if not region then
      local r, c, kind = do_motion(k2, has_count and total or nil, op)
      if not r then
        return
      end
      region = ordered_region(S.row, S.col, r, c, kind)
      if (k2 == 'w' or k2 == 'W') and region.er > S.row and not region.linewise then
        -- dw on the last word of a line must not eat the newline
        if region.ec == 0 then
          region.er = region.er - 1
          region.ec = #getline(region.er)
        end
      end
    end
  end
  apply_op(op, region)
end

-- -------------------------------------------------------------------- edits

local function put(after, count, reg)
  reg = reg or reg_read()
  count = count or 1
  if reg.linewise then
    local text = {}
    for _ = 1, count do
      for _, l in ipairs(reg.text) do
        text[#text + 1] = l
      end
    end
    local at = after and S.row or S.row - 1
    replace_lines(at, at, text)
    set_cursor(at + 1, first_nonblank(getline(at + 1)))
  else
    local line = getline(S.row)
    local col = S.col
    if after and #line > 0 then
      col = next_col(line, col)
    end
    local text = {}
    if #reg.text == 1 then
      text = { (reg.text[1]):rep(count) }
      local newline = line:sub(1, col) .. text[1] .. line:sub(col + 1)
      replace_lines(S.row - 1, S.row, { newline })
      local endb = col + #text[1]
      set_cursor(S.row, #text[1] > 0 and prev_col(newline, endb) or col)
    else
      local first = line:sub(1, col) .. reg.text[1]
      local last = reg.text[#reg.text] .. line:sub(col + 1)
      local lines = { first }
      for i = 2, #reg.text - 1 do
        lines[#lines + 1] = reg.text[i]
      end
      lines[#lines + 1] = last
      replace_lines(S.row - 1, S.row, lines)
      set_cursor(S.row, col)
    end
  end
  S.changed = true
end

local function join_lines(count)
  local n = nlines()
  local times = math.max(1, (count or 2) - 1)
  if S.row >= n then
    return
  end
  local line = getline(S.row)
  local col = 0
  for _ = 1, times do
    if S.row >= n then
      break
    end
    local nxt = getline(S.row + 1)
    local trimmed = nxt:gsub('^[ \t]+', '')
    local sep = ' '
    if trimmed == '' or line:match('[ \t]$') or trimmed:sub(1, 1) == ')' or line == '' then
      sep = ''
    end
    col = #line
    line = line .. sep .. trimmed
    replace_lines(S.row - 1, S.row + 1, { line })
    n = nlines()
  end
  set_cursor(S.row, col)
  S.changed = true
end

-- Replace only the lines that differ, so buffer listeners (gitsigns, LSP) see the
-- same narrow change events Neovim's undo produces.
local function undo_restore(snap)
  local cur, new = api.nvim_buf_get_lines(0, 0, -1, false), snap.lines
  local pre = 0
  while pre < #cur and pre < #new and cur[pre + 1] == new[pre + 1] do
    pre = pre + 1
  end
  local suf = 0
  while suf < #cur - pre and suf < #new - pre and cur[#cur - suf] == new[#new - suf] do
    suf = suf + 1
  end
  if pre < #cur - suf or pre < #new - suf then
    api.nvim_buf_set_lines(0, pre, #cur - suf, false, { unpack(new, pre + 1, #new - suf) })
  end
  S.mode = 'n'
  set_cursor(snap.row, snap.col)
end

local function do_undo()
  local snap = table.remove(S.undo)
  if not snap then
    err('Already at oldest change')
    return
  end
  local cur = api.nvim_buf_get_lines(0, 0, -1, false)
  S.redo[#S.redo + 1] = { lines = cur, row = S.row, col = S.col, seq = snap.seq, time = snap.time }
  undo_restore(snap)
  info(undo_message(cur, snap.lines, snap.seq, 'before', snap.time))
end

local function do_redo()
  local snap = table.remove(S.redo)
  if not snap then
    err('Already at newest change')
    return
  end
  local cur = api.nvim_buf_get_lines(0, 0, -1, false)
  S.undo[#S.undo + 1] = { lines = cur, row = S.row, col = S.col, seq = snap.seq, time = snap.time }
  undo_restore(snap)
  info(undo_message(cur, snap.lines, snap.seq, 'after', snap.time))
end

-- -------------------------------------------------------------- insert mode

local function insert_text(text)
  local line = getline(S.row)
  replace_lines(S.row - 1, S.row, { line:sub(1, S.col) .. text .. line:sub(S.col + 1) })
  S.col = S.col + #text
end

local function insert_newline()
  local line = getline(S.row)
  local before = line:sub(1, S.col)
  local after = line:sub(S.col + 1)
  local indent = ''
  if vim.o.autoindent or vim.o.smartindent then
    indent = before:match('^[ \t]*') or ''
    if before:match('^[ \t]*$') then
      before = ''
    end
  end
  replace_lines(S.row - 1, S.row, { before, indent .. after })
  S.row = S.row + 1
  S.col = #indent
end

local function insert_backspace()
  local line = getline(S.row)
  if S.col > 0 then
    local p = prev_col(line, S.col)
    replace_lines(S.row - 1, S.row, { line:sub(1, p) .. line:sub(S.col + 1) })
    S.col = p
  elseif S.row > 1 then
    local prev = getline(S.row - 1)
    replace_lines(S.row - 2, S.row, { prev .. line })
    S.row = S.row - 1
    S.col = #prev
  end
end

local function insert_tab()
  if vim.o.expandtab then
    local sts = vim.o.softtabstop
    local width = (type(sts) == 'number' and sts > 0) and sts or vim.o.tabstop
    if type(width) ~= 'number' or width < 1 then
      width = 8
    end
    local dc = display_col(getline(S.row), S.col, false)
    insert_text((' '):rep(width - (dc % width)))
  else
    insert_text('\t')
  end
end

-- InsertEnter/InsertLeave with the API cursor synced (blink.cmp, autopairs, ... load
-- on InsertEnter). shortcut: no ModeChanged / TextChangedI yet.
local function insert_event(event)
  pcall(api.nvim_win_set_cursor, 0, { S.row, S.col })
  local ok, e = pcall(vim._exec_autocmds, event, {})
  if not ok then
    err(tostring(e))
  end
  local pos_ok, pos = pcall(api.nvim_win_get_cursor, 0)
  if pos_ok then
    S.row, S.col = pos[1], pos[2]
  end
end

function insert_mode()
  S.mode = 'i'
  insert_event('InsertEnter')
  while not S.quit do
    local k = getkey_cmd()
    if k == '<Esc>' or k == '<C-c>' then
      break
    elseif k == '<CR>' then
      insert_newline()
    elseif k == '<BS>' then
      insert_backspace()
    elseif k == '<Del>' then
      local line = getline(S.row)
      if S.col < #line then
        replace_lines(S.row - 1, S.row, { line:sub(1, S.col) .. line:sub(next_col(line, S.col) + 1) })
      elseif S.row < nlines() then
        replace_lines(S.row - 1, S.row + 1, { line .. getline(S.row + 1) })
      end
    elseif k == '<Tab>' then
      insert_tab()
    elseif k == '<C-w>' then
      local line = getline(S.row)
      if S.col > 0 then
        local c = S.col
        while c > 0 and char_class(line, prev_col(line, c) + 1, false) == 0 do
          c = prev_col(line, c)
        end
        if c > 0 then
          local cls = char_class(line, prev_col(line, c) + 1, false)
          while c > 0 and char_class(line, prev_col(line, c) + 1, false) == cls do
            c = prev_col(line, c)
          end
        end
        replace_lines(S.row - 1, S.row, { line:sub(1, c) .. line:sub(S.col + 1) })
        S.col = c
      else
        insert_backspace()
      end
    elseif k == '<C-u>' then
      local line = getline(S.row)
      replace_lines(S.row - 1, S.row, { line:sub(S.col + 1) })
      S.col = 0
    elseif k == '<Left>' then
      S.col = prev_col(getline(S.row), S.col)
    elseif k == '<Right>' then
      S.col = next_col(getline(S.row), S.col)
    elseif k == '<Up>' or k == '<Down>' then
      local target = S.row + (k == '<Up>' and -1 or 1)
      if target >= 1 and target <= nlines() then
        S.want = S.want or cur_dcol()
        S.row = target
        S.col = col_for_display(getline(S.row), S.want, true)
      end
    elseif k == '<Home>' then
      S.col = 0
    elseif k == '<End>' then
      S.col = #getline(S.row)
    elseif not is_special(k) then
      insert_text(k)
      S.want = nil
    end
    clamp()
  end
  insert_event('InsertLeave')
  S.mode = 'n'
  S.changed = true
  local line = getline(S.row)
  if S.col > 0 then
    S.col = prev_col(line, S.col)
  end
  S.want = nil
  clamp()
end

-- ---------------------------------------------------------------- ex / cmd

local function buffer_stats()
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  local bytes = 0
  for _, l in ipairs(lines) do
    bytes = bytes + #l + 1
  end
  return #lines, bytes
end

local function clean_error(msg)
  msg = tostring(msg)
  return msg:match('(E%d+:.*)$') or msg:gsub('^.-:%d+: ', '')
end

local function ex(line)
  line = line:gsub('^[%s:]+', ''):gsub('%s+$', '')
  if line == '' then
    return
  end
  if line:match('^%d+$') then
    local n = nlines()
    local row = math.min(n, math.max(1, tonumber(line)))
    set_cursor(row, first_nonblank(getline(row)))
    return
  end
  if line == '$' then
    set_cursor(nlines(), 0)
    return
  end
  local name, bang, rest = line:match('^(%a+)(!?)%s*(.*)$')
  local modified = vim._buf_modified(0)
  local function try_quit()
    if modified and bang == '' then
      err('E37: No write since last change (add ! to override)')
    else
      S.quit = true
    end
  end
  local function write_file(path)
    local target = path ~= '' and path or api.nvim_buf_get_name(0)
    local is_new = target ~= '' and vim.uv.fs_stat(vim.fn.expand(target)) == nil
    local ok, e = pcall(vim.cmd, 'write ' .. path)
    if not ok then
      err(clean_error(e))
      return false
    end
    local nl, nb = buffer_stats()
    local fname = vim._buf_short_name(0)
    local sm = vim.o.shortmess
    info(string.format('"%s" %s%dL, %dB%s', fname, is_new and '[New] ' or '', nl, nb, sm:find('W', 1, true) and '' or ' written'))
    return true
  end
  if name == 'q' or name == 'quit' or name == 'qa' or name == 'qall' or name == 'quita' or name == 'quitall' or name == 'close' or name == 'clo' then
    try_quit()
  elseif name == 'w' or name == 'write' or name == 'up' or name == 'update' then
    write_file(rest)
  elseif name == 'wq' or name == 'x' or name == 'xit' or name == 'exit' or name == 'wqa' or name == 'wqall' or name == 'xa' or name == 'xall' then
    if modified or rest ~= '' or name == 'wq' then
      if write_file(rest) then
        S.quit = true
      end
    else
      S.quit = true
    end
  elseif name == 'noh' or name == 'nohlsearch' then
    return
  else
    local ok, e = pcall(vim.cmd, line)
    if not ok then
      err(clean_error(e))
    end
    S.mode = 'n'
    clamp()
  end
end

-- ---------------------------------------------------------- user mappings
-- Applies :map / vim.keymap.set mappings to typed keys. Only the first key of a
-- normal/visual command and every key in insert mode are mapped, so keys that are
-- arguments of d, f, r, ... are never remapped.
-- shortcut: no operator-pending or command-line maps; only <C-x> modifiers
-- (<M-x>, <S-x>, F-keys make a map unsupported and it is skipped); <expr> needs a
-- Lua callback. Upgrade when the TUI grows a real key parser with modifiers.

local NAMED_KEYS = {
  cr = '<CR>', enter = '<CR>', ['return'] = '<CR>', esc = '<Esc>', tab = '<Tab>', bs = '<BS>',
  del = '<Del>', up = '<Up>', down = '<Down>', left = '<Left>', right = '<Right>', home = '<Home>',
  ['end'] = '<End>', pageup = '<PageUp>', pagedown = '<PageDown>', space = ' ', lt = '<',
  bar = '|', bslash = '\\',
}

-- Key notation -> TUI key tokens. Returns nil when the sequence uses a key the
-- TUI cannot produce.
local function tokenize(text, out)
  out = out or {}
  local i, n = 1, #text
  while i <= n do
    local plug = text:match('^<[Pp][Ll][Uu][Gg]>%b()', i)
    local name = text:match('^<([^<>]+)>', i)
    if plug then
      out[#out + 1] = plug
      i = i + #plug
    elseif name then
      local lower = name:lower()
      if lower == 'leader' or lower == 'localleader' then
        local leader = lower == 'leader' and vim.g.mapleader or vim.g.maplocalleader
        if not tokenize((leader and leader ~= '') and leader or '\\', out) then
          return nil
        end
      elseif lower == 'nop' then
        -- produces no keys
      elseif NAMED_KEYS[lower] then
        out[#out + 1] = NAMED_KEYS[lower]
      elseif lower:match('^c%-%a$') then
        out[#out + 1] = '<C-' .. lower:sub(3) .. '>'
      else
        return nil
      end
      i = i + #name + 2
    else
      local ch = text:match('^[%z\1-\127\194-\244][\128-\191]*', i)
      out[#out + 1] = ch
      i = i + #ch
    end
  end
  return out
end

local function collect_maps(mode)
  local list = {}
  local function add(maps)
    for _, m in ipairs(maps) do
      local tokens = tokenize(m.lhs)
      if tokens and #tokens > 0 then
        list[#list + 1] = { tokens = tokens, map = m }
      end
    end
  end
  -- Buffer-local mappings come first so they win over global ones.
  pcall(function()
    add(api.nvim_buf_get_keymap(0, mode))
  end)
  pcall(function()
    add(api.nvim_get_keymap(mode))
  end)
  return list
end

local function getkey_timeout(ms)
  local k = table.remove(S.queue, 1)
  if k then
    return k
  end
  local data = vim._tty_read(ms)
  if data == nil then
    S.quit = true
    return nil
  end
  if data == '' then
    return nil
  end
  S.rbuf = S.rbuf .. data
  parse_input(true)
  return table.remove(S.queue, 1)
end

-- Callbacks and :commands see the buffer/cursor through the Neovim API, so give
-- them the TUI cursor first and take back whatever they moved.
local function with_api_cursor(fn)
  pcall(api.nvim_win_set_cursor, 0, { S.row, S.col })
  local ok, res = pcall(fn)
  local pos_ok, pos = pcall(api.nvim_win_get_cursor, 0)
  if pos_ok then
    S.row, S.col = pos[1], pos[2]
    clamp()
  end
  if not ok then
    err(clean_error(res))
    return false
  end
  return true, res
end

local function fire_map(entry, typed, depth)
  for _ = 1, #typed do
    table.remove(S.cur_keys) -- the mapping replaces the keys that were typed
  end
  local map = entry.map
  local rhs, failed
  if map.callback then
    local ok, res = with_api_cursor(map.callback)
    failed = not ok
    if ok and map.expr == 1 and type(res) == 'string' then
      rhs = res
    end
  elseif map.expr == 1 then
    local ok, res = with_api_cursor(function()
      return api.nvim_eval(map.rhs)
    end)
    failed = not ok
    rhs = ok and tostring(res) or nil
  else
    rhs = map.rhs
  end
  if rhs and rhs ~= '' then
    local cmd, rest = rhs:match('^<[Cc][Mm][Dd]>(.-)<[Cc][Rr]>(.*)$')
    if cmd then
      local mode = S.mode
      S.msg_err = false
      with_api_cursor(function()
        ex(cmd)
      end)
      failed = failed or S.msg_err
      S.mode = mode
      rhs = rest
    end
    local tokens = tokenize(rhs) or {}
    -- <Plug> keys are remapped even in a noremap rhs.
    -- shortcut: one <Plug> makes the whole rhs remappable; split per key if a plugin mixes them.
    local plug = false
    for _, t in ipairs(tokens) do
      plug = plug or t:match('^<[Pp][Ll][Uu][Gg]>') ~= nil
    end
    if map.noremap == 1 and not plug then
      for i = #tokens, 1, -1 do
        table.insert(S.inject, 1, tokens[i])
      end
    else
      queue_front(tokens)
    end
  end
  if failed then
    -- shortcut: a mapping that errors (usually a plugin calling an API zigvim lacks)
    -- falls back to the built-in meaning of the typed keys so editing keeps working;
    -- the error stays on the message line. Upgrade when plugin coverage is complete.
    for i = #typed, 1, -1 do
      table.insert(S.inject, 1, typed[i])
    end
  end
  if S.quit then
    return '<Esc>'
  end
  if depth >= 100 then
    err('E223: recursive mapping')
    return '<Esc>'
  end
  return getkey_cmd(depth + 1)
end

map_key = function(first, depth)
  if S.from_inject then
    return first
  end
  local mode = (S.mode == 'v' or S.mode == 'V') and 'x' or S.mode
  if mode ~= 'n' and mode ~= 'i' and mode ~= 'x' then
    return first
  end
  local maps = collect_maps(mode)
  if #maps == 0 then
    return first
  end
  local pending = { first }
  local best, best_len -- longest complete mapping seen so far
  while true do
    local exact, longer
    for _, entry in ipairs(maps) do
      local t = entry.tokens
      if #t >= #pending then
        local same = true
        for i = 1, #pending do
          if t[i] ~= pending[i] then
            same = false
            break
          end
        end
        if same then
          if #t == #pending then
            exact = exact or entry
          else
            longer = true
          end
        end
      end
    end
    if exact then
      best, best_len = exact, #pending
    end
    local nxt
    if longer then
      nxt = getkey_timeout(tonumber(vim.o.timeoutlen) or 1000)
    end
    if nxt then
      S.cur_keys[#S.cur_keys + 1] = nxt
      pending[#pending + 1] = nxt
    else
      -- Dead end or timeout: use the longest complete mapping, if any, and give
      -- the keys after it back to be typed again.
      local used = best_len or 1
      for i = #pending, used + 1, -1 do
        table.insert(S.queue, 1, pending[i])
        table.remove(S.cur_keys)
      end
      if best then
        local typed = {}
        for i = 1, used do
          typed[i] = pending[i]
        end
        return fire_map(best, typed, depth)
      end
      return pending[1]
    end
  end
end

local function cmdline(prefix)
  S.cmdtype = prefix
  S.cmdtext = ''
  local result
  while not S.quit do
    local k = getkey()
    if k == '<Esc>' or k == '<C-c>' then
      break
    elseif k == '<CR>' then
      result = S.cmdtext
      break
    elseif k == '<BS>' or k == '<C-h>' then
      if S.cmdtext == '' then
        break
      end
      S.cmdtext = S.cmdtext:sub(1, prev_col(S.cmdtext, #S.cmdtext))
    elseif k == '<C-u>' then
      S.cmdtext = ''
    elseif k == '<C-w>' then
      S.cmdtext = S.cmdtext:gsub('%s*[^%s]*$', '')
    elseif not is_special(k) then
      S.cmdtext = S.cmdtext .. k
    end
  end
  S.cmdtype = nil
  S.cmdtext = ''
  return result
end

-- ------------------------------------------------------------- normal mode

local function visual_region()
  local ar, ac, cr, cc = visual_bounds()
  if S.mode == 'V' then
    return { sr = ar, er = cr, sc = 0, ec = 0, linewise = true }
  end
  local ecx = next_col(getline(cr), cc)
  return { sr = ar, sc = ac, er = cr, ec = ecx, linewise = false }
end

local function exit_visual()
  S.mode = 'n'
  S.anchor = nil
  clamp()
end

local function apply_motion(k, count)
  local r, c, kind, keep = do_motion(k, count, nil)
  if r == false then
    return false
  end
  if r then
    local keep_want = keep
    set_cursor(r, c, keep_want)
    if not keep_want then
      S.want = nil
    end
  end
  return true
end

local function scroll(lines_down)
  local n = nlines()
  local textrows = math.max(1, S.rows - 2)
  local page = lines_down
  S.top = math.max(1, math.min(n, S.top + page))
  local target = math.max(1, math.min(n, S.row + page))
  S.row = target
  S.col = col_for_display(getline(S.row), S.want or cur_dcol(), false)
  clamp()
  if S.row < S.top then
    S.row = S.top
  elseif S.row > S.top + textrows - 1 then
    S.row = math.min(n, S.top + textrows - 1)
  end
  clamp()
end

local function visual_command(k, count)
  if k == '<Esc>' or k == '<C-c>' then
    exit_visual()
  elseif k == 'v' or k == 'V' then
    if S.mode == k then
      exit_visual()
    else
      S.mode = k
    end
  elseif k == 'o' or k == 'O' then
    local ar, ac = S.anchor[1], S.anchor[2]
    S.anchor = { S.row, S.col }
    set_cursor(ar, ac)
  elseif k == 'd' or k == 'x' or k == '<Del>' or k == 'y' or k == 'c' or k == 's' or k == '>' or k == '<' then
    local region = visual_region()
    local op = (k == 'x' or k == '<Del>') and 'd' or (k == 's' and 'c' or k)
    exit_visual()
    apply_op(op, region)
  elseif k == 'D' or k == 'X' or k == 'Y' or k == 'C' or k == 'S' or k == 'R' then
    local region = visual_region()
    region.linewise = true
    local op = (k == 'D' or k == 'X') and 'd' or ((k == 'Y') and 'y' or 'c')
    exit_visual()
    apply_op(op, region)
  elseif k == 'J' then
    local ar, _, cr = visual_bounds()
    exit_visual()
    set_cursor(ar, 0)
    join_lines(cr - ar + 1)
  elseif k == 'p' or k == 'P' then
    local region = visual_region()
    local saved = reg_read()
    exit_visual()
    local text, lw = region_text(region), region.linewise
    delete_region(region)
    put(false, count, saved)
    vim._reg_set(S.pending_reg or vim._reg_default(), text, lw)
    vim._reg_set('"', text, lw)
    S.changed = true
  elseif k == ':' then
    exit_visual()
    local text = cmdline(':')
    if text then
      ex(text)
    end
  elseif k == 'g' then
    local k2 = getkey()
    queue_front({ k2 })
    queue_front({ 'g' })
    if not apply_motion(getkey(), count) then
      return
    end
  else
    apply_motion(k, count)
  end
end

local function normal_command()
  S.pending_reg = nil
  vim.v.register = vim._reg_default()
  local k = getkey_cmd()
  if k == '"' then
    local name = getkey()
    if not name:match('^[%w"%-+*_/:.]$') then
      return
    end
    S.pending_reg = name
    vim.v.register = name
    k = getkey_cmd()
  end
  local count
  if k:match('^[1-9]$') then
    count = tonumber(k)
    while true do
      k = getkey()
      if k:match('^%d$') then
        count = count * 10 + tonumber(k)
      else
        break
      end
    end
  end
  local c1 = count or 1

  if S.mode == 'v' or S.mode == 'V' then
    return visual_command(k, count)
  end

  if k == 'i' then
    S.changed = true
    insert_mode()
  elseif k == 'a' then
    local line = getline(S.row)
    S.col = #line > 0 and next_col(line, S.col) or 0
    S.changed = true
    insert_mode()
  elseif k == 'I' then
    S.col = first_nonblank(getline(S.row))
    if #getline(S.row) > 0 and getline(S.row):sub(S.col + 1, S.col + 1):match('[ \t]') then
      S.col = #getline(S.row)
    end
    S.changed = true
    insert_mode()
  elseif k == 'A' then
    S.col = #getline(S.row)
    S.changed = true
    insert_mode()
  elseif k == 'o' or k == 'O' then
    local indent = ''
    if vim.o.autoindent or vim.o.smartindent then
      indent = getline(S.row):match('^[ \t]*') or ''
    end
    local at = k == 'o' and S.row or S.row - 1
    replace_lines(at, at, { indent })
    S.row = at + 1
    S.col = #indent
    S.changed = true
    insert_mode()
  elseif k == 's' then
    run_operator('c', 'l', count)
  elseif k == 'S' then
    run_operator('c', 'c', count)
  elseif k == 'x' or k == '<Del>' then
    if #getline(S.row) > 0 then
      run_operator('d', 'l', count)
    end
  elseif k == 'X' then
    run_operator('d', 'h', count)
  elseif k == 'D' then
    run_operator('d', '$', count)
  elseif k == 'C' then
    run_operator('c', '$', count)
  elseif k == 'Y' then
    run_operator('y', 'y', count)
  elseif k == 'd' or k == 'c' or k == 'y' or k == '>' or k == '<' then
    local k2 = getkey()
    local c2
    if k2:match('^[1-9]$') then
      c2 = tonumber(k2)
      while true do
        k2 = getkey()
        if k2:match('^%d$') then
          c2 = c2 * 10 + tonumber(k2)
        else
          break
        end
      end
    end
    if k2 == '<Esc>' then
      return
    end
    run_operator(k, k2, count, c2)
  elseif k == 'p' then
    put(true, c1)
  elseif k == 'P' then
    put(false, c1)
  elseif k == 'u' then
    do_undo()
  elseif k == '<C-r>' then
    do_redo()
  elseif k == '.' then
    if S.last_change then
      queue_front(S.last_change)
    end
  elseif k == 'J' then
    join_lines(count and math.max(2, count) or 2)
  elseif k == 'r' then
    local ch = getkey()
    if not is_special(ch) then
      local line = getline(S.row)
      local e = S.col
      local ok = true
      for _ = 1, c1 do
        if e >= #line then
          ok = false
          break
        end
        e = next_col(line, e)
      end
      if ok and #line > 0 then
        local last_start = prev_col(line, e)
        replace_lines(S.row - 1, S.row, { line:sub(1, S.col) .. ch:rep(c1) .. line:sub(e + 1) })
        set_cursor(S.row, S.col + #ch * (c1 - 1))
        S.changed = true
        local _ = last_start
      end
    end
  elseif k == '~' then
    local line = getline(S.row)
    if #line > 0 then
      local e = S.col
      for _ = 1, c1 do
        e = next_col(line, e)
      end
      local seg = line:sub(S.col + 1, e)
      local swapped = seg:gsub('%a', function(ch)
        if ch:match('%l') then
          return ch:upper()
        end
        return ch:lower()
      end)
      replace_lines(S.row - 1, S.row, { line:sub(1, S.col) .. swapped .. line:sub(e + 1) })
      set_cursor(S.row, math.min(e, #line))
      S.changed = true
    end
  elseif k == 'v' or k == 'V' then
    S.mode = k
    S.anchor = { S.row, S.col }
  elseif k == ':' then
    local text = cmdline(':')
    if text then
      ex(text)
    end
  elseif k == '/' or k == '?' then
    local text = cmdline(k)
    if text and text ~= '' then
      S.search = { pat = text, dir = k == '/' and 1 or -1 }
    end
    if text and S.search then
      local r, c = do_search(S.search.dir, c1)
      if r then
        set_cursor(r, c)
      end
    end
  elseif k == 'Z' then
    local k2 = getkey()
    if k2 == 'Z' then
      ex('wq')
    elseif k2 == 'Q' then
      S.quit = true
    end
  elseif k == 'z' then
    local k2 = getkey()
    local textrows = math.max(1, S.rows - 2)
    if k2 == 'z' or k2 == '.' then
      S.top = math.max(1, S.row - math.floor(textrows / 2))
    elseif k2 == 't' or k2 == '<CR>' then
      S.top = S.row
    elseif k2 == 'b' or k2 == '-' then
      S.top = math.max(1, S.row - textrows + 1)
    end
  elseif k == '<C-d>' then
    scroll(math.floor((S.rows - 2) / 2))
  elseif k == '<C-u>' then
    scroll(-math.floor((S.rows - 2) / 2))
  elseif k == '<C-f>' or k == '<PageDown>' then
    scroll(S.rows - 4)
  elseif k == '<C-b>' or k == '<PageUp>' then
    scroll(-(S.rows - 4))
  elseif k == '<C-e>' then
    S.top = math.min(nlines(), S.top + c1)
    if S.row < S.top then
      set_cursor(S.top, S.col, true)
    end
  elseif k == '<C-y>' then
    S.top = math.max(1, S.top - c1)
    local textrows = math.max(1, S.rows - 2)
    if S.row > S.top + textrows - 1 then
      set_cursor(S.top + textrows - 1, S.col, true)
    end
  elseif k == '<C-l>' then
    write('\27[2J')
  elseif k == '<C-g>' then
    local nl = nlines()
    info(string.format('"%s" %d lines --%d%%--', vim._buf_short_name(0), nl, math.floor(S.row * 100 / nl)))
  elseif k == '<Esc>' or k == '<Nop>' then
    return
  else
    local ok = apply_motion(k, count)
    if ok == false then
      -- unknown key: ignore
      return
    end
  end
end

-- ------------------------------------------------------------------ driver

local function main_loop()
  while not S.quit do
    S.cur_keys = {}
    S.cur_snap = nil
    S.changed = false
    normal_command()
    if S.changed and #S.cur_keys > 0 then
      S.last_change = S.cur_keys
    end
    if S.cur_snap then
      S.seq = (S.seq or 0) + 1
      S.cur_snap.seq, S.cur_snap.time = S.seq, vim.uv.hrtime()
      S.undo[#S.undo + 1] = S.cur_snap
      if #S.undo > 200 then
        table.remove(S.undo, 1)
      end
      S.redo = {}
    end
    S.cur_snap = nil
  end
end

function M.run()
  if not vim._tty_isatty() then
    return
  end
  local pos = api.nvim_win_get_cursor(0)
  S.row, S.col = pos[1], pos[2]
  clamp()
  if not vim._tty_raw(true) then
    io.stderr:write('zigvim: cannot enable raw terminal mode\n')
    return
  end
  write('\27[?1049h\27[2J')
  vim._tui_msg = function(text, is_err)
    local first = tostring(text):match('^[^\n]*')
    S.msg, S.msg_err = first, is_err and true or false
  end
  local ok, e = xpcall(main_loop, debug.traceback)
  write('\27[0 q\27[?25h\27[?1049l')
  vim._tty_raw(false)
  vim._tui_msg = nil
  if not ok then
    io.stderr:write('zigvim: ' .. tostring(e) .. '\n')
  end
end

vim._tui_run = M.run
-- screenrow()/screencol(): where the cursor was last drawn.
vim._tui_screen = function()
  return S.screen_row or 1, S.screen_col or 1
end

-- :normal[!] {keys}: run the keys as normal-mode commands now; an unfinished
-- command is ended as if <Esc> was typed. The pending typeahead is kept aside.
vim._tui_normal = function(keys, noremap)
  local tokens = raw_to_tokens(api.nvim_replace_termcodes(keys, true, true, true))
  local saved_queue, saved_inject, saved_in = S.queue, S.inject, S.in_normal
  local saved_reg = S.pending_reg
  S.queue, S.inject, S.in_normal = noremap and {} or tokens, noremap and tokens or {}, true
  pcall(function()
    local pos = api.nvim_win_get_cursor(0)
    S.row, S.col = pos[1], pos[2]
  end)
  local ok, e = pcall(function()
    while (#S.queue > 0 or #S.inject > 0) and not S.quit do
      normal_command()
    end
  end)
  S.queue, S.inject, S.in_normal, S.pending_reg = saved_queue, saved_inject, saved_in, saved_reg
  pcall(api.nvim_win_set_cursor, 0, { S.row, S.col })
  if not ok then
    error(e, 0)
  end
end

return M
