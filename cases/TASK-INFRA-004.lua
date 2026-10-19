-- TASK-INFRA-004: Test RPC server infrastructure
-- Verifies that basic API functions are available for RPC communication

local results = {}

-- Test 1: vim.api is available
local has_api = type(vim.api) == "table"
results[#results + 1] = { name = "api_available", pass = has_api }

if has_api then
  -- Test 2: nvim_list_bufs exists (basic buffer API)
  local has_list_bufs = type(vim.api.nvim_list_bufs) == "function"
  results[#results + 1] = { name = "has_list_bufs", pass = has_list_bufs }
  
  -- Test 3: nvim_list_wins exists (basic window API)
  local has_list_wins = type(vim.api.nvim_list_wins) == "function"
  results[#results + 1] = { name = "has_list_wins", pass = has_list_wins }
  
  -- Test 4: nvim_get_current_buf exists
  local has_current_buf = type(vim.api.nvim_get_current_buf) == "function"
  results[#results + 1] = { name = "has_current_buf", pass = has_current_buf }
  
  -- Test 5: vim.mpack is available (for RPC encoding)
  local has_mpack = type(vim.mpack) == "table"
  results[#results + 1] = { name = "has_mpack", pass = has_mpack }
  
  if has_mpack then
    -- Test 6: vim.mpack.encode exists
    local has_encode = type(vim.mpack.encode) == "function"
    results[#results + 1] = { name = "has_mpack_encode", pass = has_encode }
    
    -- Test 7: vim.mpack.decode exists
    local has_decode = type(vim.mpack.decode) == "function"
    results[#results + 1] = { name = "has_mpack_decode", pass = has_decode }
  end
  
  -- Test 8: vim.schedule exists (for async operations)
  local has_schedule = type(vim.schedule) == "function"
  results[#results + 1] = { name = "has_schedule", pass = has_schedule }
end

-- Output results as JSON
print(vim.json.encode(results))
