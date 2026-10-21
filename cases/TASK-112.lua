-- TASK-112: keymap lhs is normalized like Neovim (key notation, leader, <Space>, <S-x>)

vim.g.mapleader = " "
vim.g.maplocalleader = ","

local notations = {
  "<c-s>", "<C-S>", "<C-s>", "<leader>x", "<Leader>,", "<localleader>z", "<S-h>", "<S-H>", "<S-Tab>",
  "<S-Enter>", "<c-space>", "<C-Space>", "<c-w><space>", "<Plug>(foo)", "<cr>", "<CR>", "<Enter>",
  "<esc>", "<Esc>", "<tab>", "<bs>", "<M-j>", "<a-j>", "<A-J>", "<D-s>", "<f5>", "<F12>", "<up>",
  "<Space>y", "<lt>", "<Bar>x", "<bar>", "<Bslash>", "<c-/>", "<C-_>", "<C-S-a>", "<M-C-s>", "<c-m-s>",
  "<C-Left>", "<s-left>", "<Del>", "<kEnter>", "<nul>", "<foo>", "a<b", "gx", "\\z", "<S-1>",
  "<C-W><C-D>", "<M-Space>", "<PageUp>", "<pagedown>", "é<c-s>",
}

local function lhs_set()
  local seen = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    seen[m.lhs] = true
  end
  return seen
end

local out = {}
for _, n in ipairs(notations) do
  local before = lhs_set()
  local ok, err = pcall(vim.api.nvim_set_keymap, "n", "zz" .. n, "x", {})
  local got = "ERR"
  if ok then
    for lhs in pairs(lhs_set()) do
      if not before[lhs] then
        got = lhs
      end
    end
    -- same key spelled differently must replace, not duplicate
    pcall(vim.api.nvim_del_keymap, "n", "zz" .. n)
  else
    got = tostring(err)
  end
  out[#out + 1] = { n, got }
end

io.stdout:write(vim.json.encode(out) .. "\n")
