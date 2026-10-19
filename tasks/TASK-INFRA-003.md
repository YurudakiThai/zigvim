# TASK-INFRA-003: Implement msgpack encoder/decoder

## 🎯 Objective
Implement a complete msgpack encoder/decoder in Zig that is compatible with Neovim's msgpack format for RPC communication.

## 📋 Requirements

### 1. Msgpack Format Support
Must support all msgpack types:
- **Positive fixint**: 0x00 - 0x7f (0 - 127)
- **Fixmap**: 0x80 - 0x8f (map with 0-15 elements)
- **Fixarray**: 0x90 - 0x9f (array with 0-15 elements)
- **Fixstr**: 0xa0 - 0xbf (string with 0-31 bytes)
- **Nil**: 0xc0
- **False**: 0xc2
- **True**: 0xc3
- **Bin 8**: 0xc4 (binary data, 1-byte length)
- **Bin 16**: 0xc5 (binary data, 2-byte length)
- **Bin 32**: 0xc6 (binary data, 4-byte length)
- **Ext 8**: 0xc7 (extension type, 1-byte length)
- **Ext 16**: 0xc8 (extension type, 2-byte length)
- **Ext 32**: 0xc9 (extension type, 4-byte length)
- **Float 32**: 0xca
- **Float 64**: 0xcb
- **Uint 8**: 0xcc
- **Uint 16**: 0xcd
- **Uint 32**: 0xce
- **Uint 64**: 0xcf
- **Int 8**: 0xd0
- **Int 16**: 0xd1
- **Int 32**: 0xd2
- **Int 64**: 0xd3
- **Fixext 1**: 0xd4 (extension type, 1 byte)
- **Fixext 2**: 0xd5 (extension type, 2 bytes)
- **Fixext 4**: 0xd6 (extension type, 4 bytes)
- **Fixext 8**: 0xd7 (extension type, 8 bytes)
- **Fixext 16**: 0xd8 (extension type, 16 bytes)
- **Str 8**: 0xd9 (string, 1-byte length)
- **Str 16**: 0xda (string, 2-byte length)
- **Str 32**: 0xdb (string, 4-byte length)
- **Array 16**: 0xdc (array, 2-byte length)
- **Array 32**: 0xdd (array, 4-byte length)
- **Map 16**: 0xde (map, 2-byte length)
- **Map 32**: 0xdf (map, 4-byte length)
- **Negative fixint**: 0xe0 - 0xff (-32 to -1)

### 2. API Design

```zig
pub const Value = union(enum) {
    nil: void,
    boolean: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    binary: []const u8,
    array: []Value,
    map: []struct { key: Value, value: Value },
    ext: struct { type: i8, data: []const u8 },
};

pub fn encode(allocator: Allocator, value: Value) ![]u8
pub fn decode(allocator: Allocator, data: []const u8) !Value
pub fn decodeSlice(data: []const u8) !struct { value: Value, consumed: usize }
```

### 3. Lua Integration

Expose `vim.mpack` API:
```lua
local mpack = vim.mpack

-- Encode Lua value to msgpack bytes
local bytes = mpack.encode({1, 2, 3, "hello"})
assert(type(bytes) == "string")

-- Decode msgpack bytes to Lua value
local value = mpack.decode(bytes)
assert(vim.deep_equal(value, {1, 2, 3, "hello"}))

-- Roundtrip test
assert(vim.deep_equal(mpack.decode(mpack.encode(value)), value))
```

### 4. Test Cases

Create `cases/TASK-INFRA-003.lua` with:
- Encode/decode primitives: nil, bool, int, float, string
- Encode/decode arrays and maps
- Roundtrip tests
- Edge cases: empty string, empty array, empty map, large integers
- Binary data encoding

## ✅ Success Criteria

1. `zig build` succeeds
2. All test cases pass with output matching Neovim
3. `vim.mpack.encode()` produces valid msgpack bytes
4. `vim.mpack.decode()` can parse msgpack bytes
5. Roundtrip: `decode(encode(value))` returns original value

## 📚 References

- [Msgpack Specification](https://github.com/msgpack/msgpack/blob/master/spec.md)
- Neovim's msgpack implementation: `src/nvim/msgpack_rpc/`
