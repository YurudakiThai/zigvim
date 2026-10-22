# TASK-115: vim.fn.winsaveview / winrestview round trip

## Summary

Implement `vim.fn.winsaveview()` and `vim.fn.winrestview()` so that a saved
view can be restored and the cursor returns to the same position.

## Test

`cases/TASK-115.lua`:
1. Set buffer lines and cursor position
2. Call `vim.fn.winsaveview()` and verify it returns a table with the expected keys
3. Move the cursor
4. Call `vim.fn.winrestview(view)` and verify the cursor returns to the original position

## Expected output

```json
{
  "keys": ["col", "coladd", "curswant", "leftcol", "lnum", "skipcol", "topfill", "topline"],
  "lnum": 2,
  "col": 1,
  "coladd": 0,
  "restored": [2, 1]
}
```

## Implementation notes

- `winsaveview()` currently only tracks cursor position (lnum, col, curswant)
- `topline`, `leftcol`, `topfill`, `skipcol` are stubs (not tracked by API layer)
- `winrestview()` only restores cursor position
- Also adds `vim.api.nvim_feedkeys()` and `vim.fn.feedkeys()` implementations
- TUI support via `vim._tui_feed()` and `raw_to_tokens()` helper
