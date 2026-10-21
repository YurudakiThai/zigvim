-- Lua implementation of Neovim's runtime/plugin/matchparen.vim.
--
-- zigvim cannot source the Vimscript original, so the observable behavior is
-- reproduced here: the matchparen augroup, the :DoMatchParen / :NoMatchParen
-- commands, and highlighting of the matching bracket under the cursor through
-- extmarks. See docs/DISTRO-LOOP.md section 6 for the stub rationale.

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('zigvim.matchparen')
local pairs_open = { ['('] = ')', ['['] = ']', ['{'] = '}' }
local pairs_close = { [')'] = '(', [']'] = '[', ['}'] = '{' }

local function buffer_line(lnum)
  return api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ''
end

--- Find the matching bracket by scanning forward from {lnum, col}.
local function match_forward(lnum, col)
  local open = buffer_line(lnum):sub(col, col)
  local close = pairs_open[open]
  if not close then
    return nil
  end
  local depth = 0
  local lines = api.nvim_buf_get_lines(0, lnum - 1, -1, false)
  for offset, line in ipairs(lines) do
    local start = offset == 1 and col or 1
    for c = start, #line do
      local ch = line:sub(c, c)
      if ch == open then
        depth = depth + 1
      elseif ch == close then
        depth = depth - 1
        if depth == 0 then
          return lnum + offset - 1, c
        end
      end
    end
  end
  return nil
end

--- Find the matching bracket by scanning backward from {lnum, col}.
local function match_backward(lnum, col)
  local close = buffer_line(lnum):sub(col, col)
  local open = pairs_close[close]
  if not open then
    return nil
  end
  local depth = 0
  local first = math.max(1, lnum - 500)
  local lines = api.nvim_buf_get_lines(0, first - 1, lnum, false)
  for offset = #lines, 1, -1 do
    local line = lines[offset]
    local start = (first + offset - 1 == lnum) and math.min(col, #line) or #line
    for c = start, 1, -1 do
      local ch = line:sub(c, c)
      if ch == close then
        depth = depth + 1
      elseif ch == open then
        depth = depth - 1
        if depth == 0 then
          return first + offset - 1, c
        end
      end
    end
  end
  return nil
end

local function remove_matches()
  api.nvim_buf_clear_namespace(0, ns, 0, -1)
  vim.w.paren_hl_on = false
end

local function highlight_matching_pair()
  if vim.g.loaded_matchparen == nil then
    return
  end
  if api.nvim_get_mode().mode:sub(1, 1) == 'c' then
    return
  end
  remove_matches()
  local row, col = unpack(api.nvim_win_get_cursor(0))
  local line = buffer_line(row + 1)
  local char = line:sub(col + 1, col + 1)
  local other_row, other_col
  if pairs_open[char] then
    other_row, other_col = match_forward(row + 1, col + 1)
  elseif pairs_close[char] then
    other_row, other_col = match_backward(row + 1, col + 1)
  elseif col > 0 then
    -- The cursor sits after the bracket, as in insert mode / after ].
    char = line:sub(col, col)
    if pairs_open[char] then
      other_row, other_col = match_forward(row + 1, col)
    elseif pairs_close[char] then
      other_row, other_col = match_backward(row + 1, col)
    end
  end
  if not other_row then
    return
  end
  local ok = pcall(api.nvim_buf_set_extmark, 0, ns, row, col, {
    end_col = col + 1,
    hl_group = 'MatchParen',
  })
  if not ok then
    return
  end
  pcall(api.nvim_buf_set_extmark, 0, ns, other_row - 1, other_col - 1, {
    end_col = other_col,
    hl_group = 'MatchParen',
  })
  vim.w.paren_hl_on = true
end

local function enable_autocmds()
  local group = api.nvim_create_augroup('matchparen', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinEnter', 'WinScrolled' }, {
    group = group,
    pattern = '*',
    callback = highlight_matching_pair,
  })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    pattern = '*',
    callback = highlight_matching_pair,
  })
  api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = group,
    pattern = '*',
    callback = remove_matches,
  })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    pattern = '*',
    callback = highlight_matching_pair,
  })
  api.nvim_create_autocmd('TextChangedP', {
    group = group,
    pattern = '*',
    callback = remove_matches,
  })
end

local function disable()
  remove_matches()
  vim.g.loaded_matchparen = nil
  pcall(api.nvim_del_augroup_by_name, 'matchparen')
end

local function define_commands()
  api.nvim_create_user_command('DoMatchParen', function()
    M.enable()
  end, { desc = 'Enable the matchparen plugin' })
  api.nvim_create_user_command('NoMatchParen', function()
    disable()
  end, { desc = 'Disable the matchparen plugin' })
end

function M.enable()
  vim.g.loaded_matchparen = 1
  enable_autocmds()
  highlight_matching_pair()
end

function M.setup()
  if vim.g.loaded_matchparen then
    return
  end
  define_commands()
  M.enable()
end

return M
