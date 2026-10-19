-- TASK-INFRA-003: Test msgpack encoder/decoder
-- Tests vim.mpack.encode() and vim.mpack.decode()

local results = {}

-- Helper function to check if two values are equal
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k, v in pairs(b) do
    if not deep_equal(a[k], v) then return false end
  end
  return true
end

-- Test 1: Encode/decode positive fixint (0-127)
local bytes = vim.mpack.encode(42)
assert(type(bytes) == "string", "encode(42) should return string")
local val = vim.mpack.decode(bytes)
assert(val == 42, "decode should return 42, got " .. tostring(val))
results[#results + 1] = { name = "positive_fixint", pass = true }

-- Test 2: Encode/decode negative fixint (-32 to -1)
bytes = vim.mpack.encode(-5)
val = vim.mpack.decode(bytes)
assert(val == -5, "decode(-5) should return -5, got " .. tostring(val))
results[#results + 1] = { name = "negative_fixint", pass = true }

-- Test 3: Encode/decode larger positive int (128+)
bytes = vim.mpack.encode(1000)
val = vim.mpack.decode(bytes)
assert(val == 1000, "decode(1000) should return 1000, got " .. tostring(val))
results[#results + 1] = { name = "large_positive_int", pass = true }

-- Test 4: Encode/decode larger negative int (-128)
bytes = vim.mpack.encode(-100)
val = vim.mpack.decode(bytes)
assert(val == -100, "decode(-100) should return -100, got " .. tostring(val))
results[#results + 1] = { name = "large_negative_int", pass = true }

-- Test 5: Encode/decode fixstr (0-31 bytes)
bytes = vim.mpack.encode("hello")
val = vim.mpack.decode(bytes)
assert(val == "hello", "decode('hello') should return 'hello', got " .. tostring(val))
results[#results + 1] = { name = "fixstr", pass = true }

-- Test 6: Encode/decode empty string
bytes = vim.mpack.encode("")
val = vim.mpack.decode(bytes)
assert(val == "", "decode('') should return empty string, got " .. tostring(val))
results[#results + 1] = { name = "empty_string", pass = true }

-- Test 7: Encode/decode fixarray (0-15 elements)
bytes = vim.mpack.encode({1, 2, 3})
val = vim.mpack.decode(bytes)
assert(deep_equal(val, {1, 2, 3}), "decode([1,2,3]) should return {1,2,3}")
results[#results + 1] = { name = "fixarray", pass = true }

-- Test 8: Encode/decode empty array
bytes = vim.mpack.encode({})
val = vim.mpack.decode(bytes)
assert(deep_equal(val, {}), "decode([]) should return {}")
results[#results + 1] = { name = "empty_array", pass = true }

-- Test 9: Encode/decode fixmap (0-15 elements)
bytes = vim.mpack.encode({name = "zigvim", version = 1})
val = vim.mpack.decode(bytes)
assert(deep_equal(val, {name = "zigvim", version = 1}), "decode(map) should match")
results[#results + 1] = { name = "fixmap", pass = true }

-- Test 10: Encode/decode nested structure
local nested = {
  type = "request",
  args = {1, "test", true},
  meta = {
    timestamp = 1234567890,
    source = "zigvim"
  }
}
bytes = vim.mpack.encode(nested)
val = vim.mpack.decode(bytes)
assert(deep_equal(val, nested), "decode(nested) should match")
results[#results + 1] = { name = "nested", pass = true }

-- Test 11: Roundtrip with mixed types
local mixed = {
  bool_val = true,
  int_val = -42,
  float_val = 3.14,
  str_val = "test",
  arr_val = {1, 2, 3},
}
bytes = vim.mpack.encode(mixed)
val = vim.mpack.decode(bytes)
assert(val.bool_val == true, "bool_val should be true")
assert(val.int_val == -42, "int_val should be -42")
assert(val.str_val == "test", "str_val should be 'test'")
assert(deep_equal(val.arr_val, {1, 2, 3}), "arr_val should match")
-- Float comparison with tolerance
assert(math.abs(val.float_val - 3.14) < 0.001, "float_val should be close to 3.14")
results[#results + 1] = { name = "mixed_types", pass = true }

-- Test 12: Large array (20 elements, tests array16)
local large_arr = {}
for i = 1, 20 do
  large_arr[i] = i * 10
end
bytes = vim.mpack.encode(large_arr)
val = vim.mpack.decode(bytes)
assert(deep_equal(val, large_arr), "decode(large_array) should match")
results[#results + 1] = { name = "large_array", pass = true }

-- Test 13: Large map (20 entries, tests map16)
local large_map = {}
for i = 1, 20 do
  large_map["key" .. i] = i
end
bytes = vim.mpack.encode(large_map)
val = vim.mpack.decode(bytes)
assert(deep_equal(val, large_map), "decode(large_map) should match")
results[#results + 1] = { name = "large_map", pass = true }

-- Test 14: Boolean true
bytes = vim.mpack.encode(true)
val = vim.mpack.decode(bytes)
assert(val == true, "decode(true) should return true")
results[#results + 1] = { name = "true", pass = true }

-- Test 15: Boolean false
bytes = vim.mpack.encode(false)
val = vim.mpack.decode(bytes)
assert(val == false, "decode(false) should return false")
results[#results + 1] = { name = "false", pass = true }

-- Output results as JSON
print(vim.json.encode(results))
