-- Minimal matchit implementation for zigvim
-- Creates the mappings and commands Neovim's matchit plugin creates. Extended
-- b:match_words matching needs the Vimscript autoload file (see
-- docs/DISTRO-LOOP.md section 6).

local M = {}

-- Simple % implementation: jump to matching bracket
local function simple_match_jump(forward)
  -- For now, just use the built-in % behavior
  -- A full implementation would parse b:match_words and do extended matching
  if forward then
    return '%'
  else
    -- Backward matching is more complex, for now just use %
    return '%'
  end
end

-- Create the matchit mappings
function M.setup()
  -- Normal mode mappings
  vim.keymap.set('n', '<Plug>(MatchitNormalForward)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  vim.keymap.set('n', '<Plug>(MatchitNormalBackward)', function()
    return simple_match_jump(false)
  end, { expr = true, silent = true })
  
  vim.keymap.set('n', '<Plug>(MatchitNormalMultiForward)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  vim.keymap.set('n', '<Plug>(MatchitNormalMultiBackward)', function()
    return simple_match_jump(false)
  end, { expr = true, silent = true })
  
  -- Visual mode mappings
  vim.keymap.set('x', '<Plug>(MatchitVisualForward)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  vim.keymap.set('x', '<Plug>(MatchitVisualBackward)', function()
    return simple_match_jump(false)
  end, { expr = true, silent = true })
  
  vim.keymap.set('x', '<Plug>(MatchitVisualMultiForward)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  vim.keymap.set('x', '<Plug>(MatchitVisualMultiBackward)', function()
    return simple_match_jump(false)
  end, { expr = true, silent = true })
  
  vim.keymap.set('x', '<Plug>(MatchitVisualTextObject)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  -- Operator-pending mode mappings
  vim.keymap.set('o', '<Plug>(MatchitOperationForward)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  vim.keymap.set('o', '<Plug>(MatchitOperationBackward)', function()
    return simple_match_jump(false)
  end, { expr = true, silent = true })
  
  vim.keymap.set('o', '<Plug>(MatchitOperationMultiForward)', function()
    return simple_match_jump(true)
  end, { expr = true, silent = true })
  
  vim.keymap.set('o', '<Plug>(MatchitOperationMultiBackward)', function()
    return simple_match_jump(false)
  end, { expr = true, silent = true })
  
  if vim.g.no_plugin_maps then
    return
  end

  -- User-facing mappings: %, g%, [%, ]%
  vim.keymap.set('n', '%', '<Plug>(MatchitNormalForward)', { silent = true })
  vim.keymap.set('n', 'g%', '<Plug>(MatchitNormalBackward)', { silent = true })
  vim.keymap.set('n', '[%', '<Plug>(MatchitNormalMultiBackward)', { silent = true })
  vim.keymap.set('n', ']%', '<Plug>(MatchitNormalMultiForward)', { silent = true })
  
  vim.keymap.set('x', '%', '<Plug>(MatchitVisualForward)', { silent = true })
  vim.keymap.set('x', 'g%', '<Plug>(MatchitVisualBackward)', { silent = true })
  vim.keymap.set('x', '[%', '<Plug>(MatchitVisualMultiBackward)', { silent = true })
  vim.keymap.set('x', ']%', '<Plug>(MatchitVisualMultiForward)', { silent = true })
  vim.keymap.set('x', 'a%', '<Plug>(MatchitVisualTextObject)', { silent = true })
  
  vim.keymap.set('o', '%', '<Plug>(MatchitOperationForward)', { silent = true })
  vim.keymap.set('o', 'g%', '<Plug>(MatchitOperationBackward)', { silent = true })
  vim.keymap.set('o', '[%', '<Plug>(MatchitOperationMultiBackward)', { silent = true })
  vim.keymap.set('o', ']%', '<Plug>(MatchitOperationMultiForward)', { silent = true })
end

-- :MatchDisable removes only the user-facing maps, leaving the <Plug> ones.
function M.disable()
  for _, mode in ipairs({ 'n', 'x', 'o' }) do
    for _, lhs in ipairs({ '%', 'g%', '[%', ']%' }) do
      pcall(vim.api.nvim_del_keymap, mode, lhs)
    end
  end
  pcall(vim.api.nvim_del_keymap, 'x', 'a%')
end

function M.debug()
  vim.b.match_debug = 1
  vim.b.match_words = vim.b.match_words or ''
end

function M.define_commands()
  if vim.fn.exists(':MatchEnable') == 0 then
    vim.api.nvim_create_user_command('MatchEnable', function()
      M.setup()
    end, { desc = 'Enable extended % matching' })
  end
  if vim.fn.exists(':MatchDisable') == 0 then
    vim.api.nvim_create_user_command('MatchDisable', function()
      M.disable()
    end, { desc = 'Disable extended % matching' })
  end
  if vim.fn.exists(':MatchDebug') == 0 then
    vim.api.nvim_create_user_command('MatchDebug', function()
      M.debug()
    end, { desc = 'Save matchit debug information for the buffer' })
  end
end

return M
