-- TASK-110: Neovim runtime modules (fs, iter, text, filetype, hl, diagnostic)

local out = {}

-- Namespaces: stable by name, distinct ids.
local ns_a = vim.api.nvim_create_namespace('zigvim.test.a')
local ns_a2 = vim.api.nvim_create_namespace('zigvim.test.a')
local ns_b = vim.api.nvim_create_namespace('zigvim.test.b')
out.namespace = {stable = ns_a == ns_a2, distinct = ns_a ~= ns_b, positive = ns_a > 0}

-- Highlight groups.
vim.api.nvim_set_hl(0, 'ZigFg', {fg = '#ff0000', bold = true})
vim.api.nvim_set_hl(0, 'ZigLink', {link = 'ZigFg'})
local fg = vim.api.nvim_get_hl(0, {name = 'ZigFg', link = false})
out.hl = {fg = fg.fg, bold = fg.bold, link = vim.api.nvim_get_hl(0, {name = 'ZigLink'}).link}

-- vim.fs
out.fs = {
  joinpath = vim.fs.joinpath('a', 'b', 'c'),
  normalize = vim.fs.normalize('/a/./b/../c'),
  dirname = vim.fs.dirname('/a/b/c.txt'),
  basename = vim.fs.basename('/a/b/c.txt'),
}

local parents = {}
for dir in vim.fs.parents('/a/b/c') do
  parents[#parents + 1] = dir
end
out.fs_parents = parents

-- vim.iter
out.iter = vim.iter({1, 2, 3, 4})
  :map(function(x)
    return x * 2
  end)
  :filter(function(x)
    return x > 4
  end)
  :totable()
out.iter_pairs = vim.iter({a = 1, b = 2}):fold(0, function(acc, _, v)
  return acc + v
end)

-- vim.text
out.text = {
  hexencode = vim.text.hexencode('ab'),
  hexdecode = vim.text.hexdecode('6162'),
}

-- vim.F
out.if_nil = {vim.F.if_nil(nil, 5), vim.F.if_nil(1, 5)}

-- vim.filetype
out.filetype = {
  lua = vim.filetype.match({filename = 'init.lua'}),
  python = vim.filetype.match({filename = 'setup.py'}),
  unknown = vim.filetype.match({filename = 'noext'}),
}

-- vim.diagnostic
vim.diagnostic.set(ns_a, 0, {
  {lnum = 0, col = 0, message = 'first', severity = vim.diagnostic.severity.WARN},
  {lnum = 1, col = 0, message = 'second', severity = vim.diagnostic.severity.ERROR},
})
local diags = vim.diagnostic.get(0, {namespace = ns_a})
out.diagnostic = {
  count = #diags,
  first = {message = diags[1].message, severity = diags[1].severity, lnum = diags[1].lnum},
  second = {message = diags[2].message, severity = diags[2].severity},
  error_level = vim.diagnostic.severity.ERROR,
}
vim.diagnostic.reset(ns_a, 0)
out.diagnostic_after_reset = #vim.diagnostic.get(0, {namespace = ns_a})

-- Module availability
out.modules = {
  fs = type(vim.fs),
  iter = type(vim.iter),
  text = type(vim.text),
  range = type(vim.range),
  re = type(vim.re),
  pos = type(vim.pos),
  net = type(vim.net),
  secure = type(vim.secure),
  pack = type(vim.pack),
  health = type(vim.health),
  loader = type(vim.loader),
  hl = type(vim.hl),
  diagnostic = type(vim.diagnostic),
  lsp = type(vim.lsp),
  uv = type(vim.uv),
}

out.version_major = type(vim.version().major)

io.stdout:write(vim.json.encode(out) .. '\n')
