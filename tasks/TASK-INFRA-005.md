# TASK-INFRA-005: Implement RPC request/response dispatch

## Objective
Implement msgpack-RPC server that can parse incoming requests from stdin, route them to appropriate handlers, and send responses back via stdout.

## Neovim RPC Protocol

### Message Types

1. **Request**: `[0, msgid, method, params]`
   - `msgid`: uint32 unique identifier
   - `method`: string (e.g., "nvim_eval", "nvim_command")
   - `params`: array of arguments

2. **Response**: `[1, msgid, error, result]`
   - `msgid`: uint32 matching the request
   - `error`: null or error object
   - `result`: return value

3. **Notification**: `[2, method, params]`
   - Same as request but no msgid, no response expected

## Requirements

### 1. Read msgpack from stdin
- Read raw bytes from stdin
- Decode msgpack messages
- Handle partial reads (messages may be split)

### 2. Parse message type
- Check first element of array:
  - `0` = Request → send response
  - `1` = Response → ignore (we don't make requests)
  - `2` = Notification → no response

### 3. Route requests to handlers
- Extract method name and params
- Call appropriate `vim.api.*` function
- Encode result as msgpack

### 4. Send response
- For requests: send `[1, msgid, null, result]`
- For errors: send `[1, msgid, error_obj, null]`
- Write to stdout

### 5. Handle common methods
- `nvim_get_api_info`: return `[channel_id, api_metadata]`
- `nvim_eval`: evaluate vimscript expression
- `nvim_command`: execute command
- `nvim_call_function`: call vim function

## Test Cases

1. **Basic handshake**
   - Send `[0, 1, "nvim_get_api_info", []]`
   - Expect response with channel ID and API metadata

2. **Simple request**
   - Send `[0, 2, "nvim_eval", ["1+1"]]`
   - Expect `[1, 2, null, 2]`

3. **Notification**
   - Send `[2, "redraw", [...]]`
   - Expect no response

4. **Invalid method**
   - Send `[0, 3, "invalid_method", []]`
   - Expect error response

## Implementation Notes

- Use msgpack encoder/decoder from TASK-INFRA-003
- Run event loop to handle async I/O
- Buffer incomplete messages until complete
- Handle multiple messages in one read

## Success Criteria

- zigvim can respond to `nvim_get_api_info` request
- External RPC client can connect and execute commands
- Messages are properly encoded/decoded
- Error cases return appropriate error responses
