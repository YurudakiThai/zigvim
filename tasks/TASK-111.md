# TASK-111: vim.fn editing helpers

**Status:** ✅ Complete (verified against Neovim 0.12.6)
**Priority:** High
**Platform:** All

## 🎯 Objective

Test `vim.fn` editing helpers: `getline`, `setline`, `append`, `line`, `col`, `bufnr`, `bufname`, `bufexists`, `getbufline`, `getbufvar`, `setbufvar`, `getwinvar`, `getreg`, `getregtype`, `strwidth`, `strchars`, `strlen`, `toupper`, `tolower`, `split`, `join`, `stridx`, `strpart`, `repeat`, `escape`, `fnameescape`, `shellexists`, `exists`, `expand`, `mode`, `winheight`, `winwidth`, `winnr`, `tabpagenr`, `getcwd`, and `setreg`.

## 📋 Requirements

Each `vim.fn` helper must behave identically to Neovim 0.12.6:

- `vim.fn.getline` - Get buffer line(s)
- `vim.fn.setline` - Set buffer line
- `vim.fn.append` - Append lines after a position
- `vim.fn.line` - Return line number
- `vim.fn.col` - Return column number
- `vim.fn.bufnr` - Return buffer number
- `vim.fn.bufname` - Return buffer name
- `vim.fn.bufexists` - Check if buffer exists
- `vim.fn.getbufline` - Get a range of lines from a buffer
- `vim.fn.getbufvar` - Get buffer variable
- `vim.fn.setbufvar` - Set buffer variable
- `vim.fn.getwinvar` - Get window variable
- `vim.fn.getreg` - Get register contents
- `vim.fn.getregtype` - Get register type
- `vim.fn.strwidth` - Display width of string
- `vim.fn.strchars` - Number of bytes/characters
- `vim.fn.strlen` - Length of string
- `vim.fn.toupper` - Convert to uppercase
- `vim.fn.tolower` - Convert to lowercase
- `vim.fn.split` - Split string
- `vim.fn.join` - Join list with delimiter
- `vim.fn.stridx` - Find start position of pattern
- `vim.fn.strpart` - Extract substring
- `vim.fn['repeat']` - Repeat string n times
- `vim.fn.escape` - Escape magic characters
- `vim.fn.fnameescape` - Escape filename characters
- `vim.fn.shellescape` - Escape for shell
- `vim.fn.exists` - Check if variable/function exists
- `vim.fn.expand` - Expand patterns like `%`, `$HOME`
- `vim.fn.mode` - Return current mode
- `vim.fn.winheight` - Window height
- `vim.fn.winwidth` - Window width
- `vim.fn.winnr` - Window number
- `vim.fn.tabpagenr` - Tab page number
- `vim.fn.getcwd` - Get current working directory

## 🧪 Verification

```bash
./scripts/verify.sh TASK-111
```

Case: `cases/TASK-111.lua` — compares against Neovim 0.12.6.