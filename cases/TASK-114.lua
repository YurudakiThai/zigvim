-- TASK-114: fs_stat time shape, getftime/getfsize, and vim.treesitter without parsers

local path = vim.fn.tempname()
local f = assert(io.open(path, "w"))
f:write("hello")
f:close()

local st = vim.uv.fs_stat(path)
local out = {
  type = st.type,
  size = st.size,
  mtime_sec_is_number = type(st.mtime.sec) == "number",
  mtime_nsec_is_number = type(st.mtime.nsec) == "number",
  getftime_positive = vim.fn.getftime(path) > 0,
  getftime_matches_stat = vim.fn.getftime(path) == st.mtime.sec,
  getfsize = vim.fn.getfsize(path),
  getftime_missing = vim.fn.getftime(path .. ".nope"),
  getfsize_missing = vim.fn.getfsize(path .. ".nope"),
  stat_missing = vim.uv.fs_stat(path .. ".nope") == nil,
  ts_is_table = type(vim.treesitter) == "table",
  ts_start_is_function = type(vim.treesitter.start) == "function",
  ts_highlighter_is_table = type(vim.treesitter.highlighter) == "table",
}
os.remove(path)

io.stdout:write(vim.json.encode(out) .. "\n")
