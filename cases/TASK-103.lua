-- TASK-103: File edit/write commands and basic vim.fn conformance

local path = "/tmp/zigvim_task103.txt"
os.remove(path)

local out = {}

vim.cmd("silent edit " .. path)
out.name_after_edit = vim.api.nvim_buf_get_name(0)

vim.api.nvim_buf_set_lines(0, 0, -1, false, {"line1", "line2"})
out.modified_before_write = vim.bo.modified
vim.cmd("silent write")
out.modified_after_write = vim.bo.modified

local f = io.open(path, "rb")
out.file_contents = f:read("*a")
f:close()

out.filereadable = vim.fn.filereadable(path)
out.expand_percent = vim.fn.expand("%")
out.expand_percent_tail = vim.fn.expand("%:t")
out.fnamemodify = vim.fn.fnamemodify(path, ":t")

vim.cmd("silent enew")
out.after_enew = vim.api.nvim_buf_get_name(0)
vim.cmd("silent edit " .. path)
out.reloaded_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

os.remove(path)
io.stdout:write(vim.json.encode(out) .. "\n")
