-- TASK-128: tabpage <-> window APIs (oil.nvim uses nvim_tabpage_list_wins)

local function err(f)
  local ok, e = pcall(f)
  return ok and 'ok' or (tostring(e):match('Invalid.*') or tostring(e))
end
local wins = vim.api.nvim_tabpage_list_wins(0)

io.stdout:write(vim.json.encode({
  list_is_all = vim.deep_equal(wins, vim.api.nvim_list_wins()),
  list_cur = vim.deep_equal(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage()), wins),
  win_tab = vim.api.nvim_win_get_tabpage(0) == vim.api.nvim_get_current_tabpage(),
  set_win = err(function() vim.api.nvim_tabpage_set_win(0, wins[1]) end),
  set_tab = err(function() vim.api.nvim_set_current_tabpage(0) end),
  bad_tab = err(function() vim.api.nvim_tabpage_list_wins(99) end),
  bad_win = err(function() vim.api.nvim_win_get_tabpage(9999) end),
  bad_set = err(function() vim.api.nvim_tabpage_set_win(0, 9999) end),
  bad_cur = err(function() vim.api.nvim_set_current_tabpage(99) end),
}) .. "\n")
