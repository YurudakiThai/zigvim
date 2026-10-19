-- TASK-106: API error and validation conformance

local out = {}
local function cap(f, ...)
  local ok, err = pcall(f, ...)
  return { ok = ok, err = tostring(err) }
end

out.var_missing = cap(vim.api.nvim_get_var, "missing")
out.var_delete_missing = cap(vim.api.nvim_del_var, "missing")
out.buf_lines_invalid = cap(vim.api.nvim_buf_get_lines, 999, 0, -1, false)
out.buf_name_invalid = cap(vim.api.nvim_buf_set_name, 999, "x")
out.buf_delete_invalid = cap(vim.api.nvim_buf_delete, 999, {})
out.set_current_buf_invalid = cap(vim.api.nvim_set_current_buf, 999)
out.buf_call_invalid = cap(vim.api.nvim_buf_call, 999, function() end)

out.option_unknown = cap(vim.api.nvim_set_option_value, "nosuchopt", 1, {})
out.option_get_unknown = cap(vim.api.nvim_get_option_value, "nosuchopt", {})
out.buf_option_unknown = cap(vim.api.nvim_buf_get_option, 0, "nosuchopt")
out.win_option_unknown = cap(vim.api.nvim_win_get_option, 0, "nosuchopt")

out.command_unknown = cap(vim.api.nvim_command, "NoSuchCommand")
out.vim_cmd_unknown = cap(vim.cmd, "NoSuchCommand")
out.keymap_delete_missing = cap(vim.api.nvim_del_keymap, "n", "<Plug>(missing)")
out.buf_keymap_delete_missing = cap(vim.api.nvim_buf_del_keymap, 0, "n", "<Plug>(missing)")
out.user_command_delete_missing = cap(vim.api.nvim_del_user_command, "MissingCommand")

out.cursor_row_zero = cap(vim.api.nvim_win_set_cursor, 0, {0, 0})
out.cursor_row_past_end = cap(vim.api.nvim_win_set_cursor, 0, {99, 0})
out.win_invalid = cap(vim.api.nvim_win_get_height, 999)
out.win_set_current_invalid = cap(vim.api.nvim_set_current_win, 999)
out.tabpage_var_invalid = cap(vim.api.nvim_tabpage_get_var, 999, "x")

out.buf_valid_0 = vim.api.nvim_buf_is_valid(0)
out.buf_valid_999 = vim.api.nvim_buf_is_valid(999)
out.buf_valid_negative = vim.api.nvim_buf_is_valid(-1)
out.win_valid_999 = vim.api.nvim_win_is_valid(999)
out.tabpage_valid_999 = vim.api.nvim_tabpage_is_valid(999)

out.strwidth = {
  ascii = vim.api.nvim_strwidth("abc"),
  cjk = vim.api.nvim_strwidth("日本語"),
  combining = vim.api.nvim_strwidth("e\204\129"),
  emoji = vim.api.nvim_strwidth("😀"),
  arrow = vim.api.nvim_strwidth("→"),
  hangul = vim.api.nvim_strwidth("한"),
  tab = vim.api.nvim_strwidth("\t"),
  newline = vim.api.nvim_strwidth("a\nb"),
  empty = vim.api.nvim_strwidth(""),
}
out.strwidth_bad_arg = cap(vim.api.nvim_strwidth, 12)

io.stdout:write(vim.json.encode(out) .. "\n")
