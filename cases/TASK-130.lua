-- TASK-130: indent(), nvim_win_get_config() for a normal window, getbufinfo()

vim.api.nvim_buf_set_lines(0, 0, -1, false, { '  two', '\tx', 'none', ' \t mixed' })
vim.bo.tabstop = 8
vim.b.v130 = 'yes'
local cfg = vim.api.nvim_win_get_config(0)
local info = vim.fn.getbufinfo(1)[1]
local keys = vim.tbl_keys(info)
table.sort(keys)
local scratch = vim.api.nvim_create_buf(false, true)

io.stdout:write(vim.json.encode({
  indent = { vim.fn.indent(1), vim.fn.indent(2), vim.fn.indent(3), vim.fn.indent(4), vim.fn.indent(99), vim.fn.indent(0) },
  cfg = { cfg.relative, cfg.split, cfg.focusable, cfg.external, cfg.hide, cfg.mouse, cfg.style },
  cfg_size = cfg.width == vim.api.nvim_win_get_width(0) and cfg.height == vim.api.nvim_win_get_height(0),
  keys = keys,
  info = { info.bufnr, info.changed, info.listed, info.loaded, info.linecount, info.hidden, info.name, info.variables.v130, #info.windows },
  counts = { #vim.fn.getbufinfo(), #vim.fn.getbufinfo({ buflisted = 1 }), #vim.fn.getbufinfo(99) },
  scratch_listed = vim.fn.getbufinfo(scratch)[1].listed,
  scratch_opts = { vim.bo[scratch].buftype, vim.bo[scratch].bufhidden, vim.bo[scratch].swapfile, vim.bo[scratch].buflisted },
  plain_opts = { vim.bo[vim.api.nvim_create_buf(true, false)].buflisted, vim.bo[1].buftype },
}) .. "\n")
