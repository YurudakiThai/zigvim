-- Lua implementation of Neovim's runtime/plugin/tutor.vim.
--
-- The lesson files themselves are the Vim tutor text files from the Neovim
-- runtime (tutor/tutor and tutor/tutor.<lang>); zigvim opens them the same way
-- tutor#TutorCmd does. If the runtime does not ship them the command reports
-- the missing file instead of failing silently.

local api = vim.api

local M = {}

local function find_tutor(lang)
  local name = (lang ~= nil and lang ~= '') and ('tutor/tutor.' .. lang) or 'tutor/tutor'
  return api.nvim_get_runtime_file(name, false)[1]
end

local function open_tutor(lang)
  local path = find_tutor(lang)
  if not path then
    error(('Tutor: could not find tutor file for language %q'):format(lang or ''), 0)
  end
  vim.cmd.edit({ args = { path } })
  vim.bo.filetype = 'tutor'
end

function M.complete(arg_lead)
  local names = {}
  for _, file in ipairs(api.nvim_get_runtime_file('tutor/tutor*', true)) do
    local lang = file:match('tutor%.([^.]+)$')
    if lang and (arg_lead == '' or lang:sub(1, #arg_lead) == arg_lead) then
      names[#names + 1] = lang
    end
  end
  table.sort(names)
  return names
end

function M.setup()
  if vim.g.loaded_tutor_mode_plugin then
    return
  end
  vim.g.loaded_tutor_mode_plugin = 1
  api.nvim_create_user_command('Tutor', function(cmd)
    open_tutor(cmd.args)
  end, {
    nargs = '?',
    complete = function(arg_lead)
      return M.complete(arg_lead)
    end,
    desc = 'Open the Neovim tutor',
  })
end

return M
