# TASK-INFRA-004: Implement RPC server (stdin/stdout)

## 🎯 Objective
Implement a msgpack-RPC server that listens on stdin/stdout when `--embed` flag is used, allowing external UI clients (neovide, nvim-qt, etc.) to connect to zigvim.

## 📋 Requirements

### 1. RPC Protocol

Implement the msgpack-RPC protocol with three message types:

**Request (type=0):**
```
[0, msgid, method, params]
```
- `msgid`: uint32 - unique request identifier
- `method`: string - method name (e.g., "nvim_get_api_info")
- `params`: array - method parameters

**Response (type=1):**
```
[1, msgid, error, result]
```
- `msgid`: uint32 - matches the request msgid
- `error`: nil or [code, message] - error if request failed
- `result`: any - return value

**Notification (type=2):**
```
[2, method, params]
```
- `method`: string - method name
- `params`: array - method parameters
- No response expected

### 2. RPC Server API

```zig
pub const RpcServer = struct {
    pub fn init(allocator: Allocator, stdin: std.fs.File, stdout: std.fs.File) !RpcServer
    pub fn deinit(self: *RpcServer) void
    
    // Main event loop - reads requests and dispatches to handlers
    pub fn run(self: *RpcServer) !void
    
    // Send response to a request
    pub fn sendResponse(self: *RpcServer, msgid: u32, result: msgpack.Value, error: ?msgpack.Value) !void
    
    // Send notification
    pub fn sendNotification(self: *RpcServer, method: []const u8, params: []const msgpack.Value) !void
    
    // Register method handler
    pub fn registerMethod(self: *RpcServer, method: []const u8, handler: *const fn ([]const msgpack.Value) msgpack.Value) !void
};
```

### 3. Message Framing

- Read from stdin in binary mode
- Handle partial reads (messages may arrive in chunks)
- Handle multiple messages in a single read
- Buffer incomplete messages until complete

### 4. Required Methods

At minimum, implement:
- `nvim_get_api_info`: Return API metadata (version, functions, etc.)
- `nvim_eval`: Evaluate VimL expression (stub for now)
- `nvim_command`: Execute Vim command (stub for now)

### 5. Test Cases

Create `cases/TASK-INFRA-004.lua` with:
- Test `--embed` mode starts RPC server
- Test `nvim_get_api_info` returns valid response
- Test request/response cycle
- Test notification handling

## ✅ Success Criteria

1. `zig build` succeeds
2. `zigvim --embed` starts and listens on stdin/stdout
3. Can send msgpack-RPC request to `nvim_get_api_info` and receive response
4. Multiple requests can be handled in sequence
5. Notifications are processed without response
6. Test cases pass with output matching Neovim

## 📚 References

- [msgpack-RPC Specification](https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md)
- Neovim's RPC implementation: `src/nvim/msgpack_rpc/`
- Neovim's `--embed` flag documentation
