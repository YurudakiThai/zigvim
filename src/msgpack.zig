//! Msgpack encoder/decoder for Neovim RPC protocol
//! Implements: https://github.com/msgpack/msgpack/blob/master/spec.md

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Msgpack value types
pub const Value = union(enum) {
    nil: void,
    boolean: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    binary: []const u8,
    array: []const Value,
    map: []const MapEntry,
    ext: Ext,

    pub const MapEntry = struct {
        key: Value,
        value: Value,
    };

    pub const Ext = struct {
        type: i8,
        data: []const u8,
    };
};

/// Encoding errors
pub const EncodeError = error{
    OutOfMemory,
    InvalidData,
};

/// Decoding errors
pub const DecodeError = error{
    InvalidMsgpack,
    OutOfMemory,
    BufferTooSmall,
};

/// Encoder state
pub const Encoder = struct {
    buffer: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Encoder {
        return .{
            .buffer = std.ArrayList(u8).initCapacity(allocator, 64) catch @panic("OOM"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn encode(self: *Encoder, value: Value) EncodeError!void {
        switch (value) {
            .nil => try self.encodeNil(),
            .boolean => |b| try self.encodeBool(b),
            .int => |i| try self.encodeInt(i),
            .uint => |u| try self.encodeUint(u),
            .float => |f| try self.encodeFloat(f),
            .string => |s| try self.encodeString(s),
            .binary => |b| try self.encodeBinary(b),
            .array => |arr| try self.encodeArray(arr),
            .map => |m| try self.encodeMap(m),
            .ext => |e| try self.encodeExt(e),
        }
    }

    fn encodeNil(self: *Encoder) !void {
        try self.buffer.append(self.allocator, 0xc0);
    }

    fn encodeBool(self: *Encoder, b: bool) !void {
        try self.buffer.append(self.allocator, if (b) 0xc3 else 0xc2);
    }

    fn encodeInt(self: *Encoder, i: i64) !void {
        if (i >= 0) {
            return self.encodeUint(@intCast(i));
        }

        // Negative fixint: -32 to -1 (0xe0 - 0xff)
        if (i >= -32) {
            try self.buffer.append(self.allocator, @intCast(i & 0xff));
        }
        // Int 8: -128 to -33
        else if (i >= -128) {
            try self.buffer.append(self.allocator, 0xd0);
            try self.buffer.append(self.allocator, @intCast(i & 0xff));
        }
        // Int 16
        else if (i >= -32768) {
            try self.buffer.append(self.allocator, 0xd1);
            const big = std.mem.nativeToBig(i16, @intCast(i));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Int 32
        else if (i >= -2147483648) {
            try self.buffer.append(self.allocator, 0xd2);
            const big = std.mem.nativeToBig(i32, @intCast(i));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Int 64
        else {
            try self.buffer.append(self.allocator, 0xd3);
            const big = std.mem.nativeToBig(i64, i);
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
    }

    fn encodeUint(self: *Encoder, u: u64) !void {
        // Positive fixint: 0 to 127 (0x00 - 0x7f)
        if (u <= 127) {
            try self.buffer.append(self.allocator, @intCast(u));
        }
        // Uint 8
        else if (u <= 255) {
            try self.buffer.append(self.allocator, 0xcc);
            try self.buffer.append(self.allocator, @intCast(u));
        }
        // Uint 16
        else if (u <= 65535) {
            try self.buffer.append(self.allocator, 0xcd);
            const big = std.mem.nativeToBig(u16, @intCast(u));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Uint 32
        else if (u <= 4294967295) {
            try self.buffer.append(self.allocator, 0xce);
            const big = std.mem.nativeToBig(u32, @intCast(u));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Uint 64
        else {
            try self.buffer.append(self.allocator, 0xcf);
            const big = std.mem.nativeToBig(u64, u);
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
    }

    fn encodeFloat(self: *Encoder, f: f64) !void {
        // Always use float64 for simplicity
        try self.buffer.append(self.allocator, 0xcb);
        const bits: u64 = @bitCast(f);
        const big = std.mem.nativeToBig(u64, bits);
        try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
    }

    fn encodeString(self: *Encoder, s: []const u8) !void {
        const len = s.len;

        // Fixstr: 0 to 31 bytes (0xa0 - 0xbf)
        if (len <= 31) {
            try self.buffer.append(self.allocator, @intCast(0xa0 | len));
        }
        // Str 8
        else if (len <= 255) {
            try self.buffer.append(self.allocator, 0xd9);
            try self.buffer.append(self.allocator, @intCast(len));
        }
        // Str 16
        else if (len <= 65535) {
            try self.buffer.append(self.allocator, 0xda);
            const big = std.mem.nativeToBig(u16, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Str 32
        else {
            try self.buffer.append(self.allocator, 0xdb);
            const big = std.mem.nativeToBig(u32, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }

        try self.buffer.appendSlice(self.allocator, s);
    }

    fn encodeBinary(self: *Encoder, b: []const u8) !void {
        const len = b.len;

        // Bin 8
        if (len <= 255) {
            try self.buffer.append(self.allocator, 0xc4);
            try self.buffer.append(self.allocator, @intCast(len));
        }
        // Bin 16
        else if (len <= 65535) {
            try self.buffer.append(self.allocator, 0xc5);
            const big = std.mem.nativeToBig(u16, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Bin 32
        else {
            try self.buffer.append(self.allocator, 0xc6);
            const big = std.mem.nativeToBig(u32, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }

        try self.buffer.appendSlice(self.allocator, b);
    }

    fn encodeArrayHeader(self: *Encoder, len: usize) !void {
        // Fixarray: 0 to 15 elements (0x90 - 0x9f)
        if (len <= 15) {
            try self.buffer.append(self.allocator, @intCast(0x90 | len));
        }
        // Array 16
        else if (len <= 65535) {
            try self.buffer.append(self.allocator, 0xdc);
            const big = std.mem.nativeToBig(u16, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Array 32
        else {
            try self.buffer.append(self.allocator, 0xdd);
            const big = std.mem.nativeToBig(u32, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
    }

    fn encodeArray(self: *Encoder, arr: []const Value) !void {
        try self.encodeArrayHeader(arr.len);
        for (arr) |elem| {
            try self.encode(elem);
        }
    }

    fn encodeMapHeader(self: *Encoder, len: usize) !void {
        // Fixmap: 0 to 15 elements (0x80 - 0x8f)
        if (len <= 15) {
            try self.buffer.append(self.allocator, @intCast(0x80 | len));
        }
        // Map 16
        else if (len <= 65535) {
            try self.buffer.append(self.allocator, 0xde);
            const big = std.mem.nativeToBig(u16, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
        // Map 32
        else {
            try self.buffer.append(self.allocator, 0xdf);
            const big = std.mem.nativeToBig(u32, @intCast(len));
            try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
        }
    }

    fn encodeMap(self: *Encoder, m: []const Value.MapEntry) !void {
        try self.encodeMapHeader(m.len);
        for (m) |entry| {
            try self.encode(entry.key);
            try self.encode(entry.value);
        }
    }

    fn encodeExt(self: *Encoder, e: Value.Ext) !void {
        const len = e.data.len;

        switch (len) {
            1 => {
                try self.buffer.append(self.allocator, 0xd4);
                try self.buffer.append(self.allocator, @bitCast(e.type));
            },
            2 => {
                try self.buffer.append(self.allocator, 0xd5);
                try self.buffer.append(self.allocator, @bitCast(e.type));
            },
            4 => {
                try self.buffer.append(self.allocator, 0xd6);
                try self.buffer.append(self.allocator, @bitCast(e.type));
            },
            8 => {
                try self.buffer.append(self.allocator, 0xd7);
                try self.buffer.append(self.allocator, @bitCast(e.type));
            },
            16 => {
                try self.buffer.append(self.allocator, 0xd8);
                try self.buffer.append(self.allocator, @bitCast(e.type));
            },
            else => {
                if (len <= 255) {
                    try self.buffer.append(self.allocator, 0xc7);
                    try self.buffer.append(self.allocator, @intCast(len));
                    try self.buffer.append(self.allocator, @bitCast(e.type));
                } else if (len <= 65535) {
                    try self.buffer.append(self.allocator, 0xc8);
                    const big = std.mem.nativeToBig(u16, @intCast(len));
                    try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
                    try self.buffer.append(self.allocator, @bitCast(e.type));
                } else {
                    try self.buffer.append(self.allocator, 0xc9);
                    const big = std.mem.nativeToBig(u32, @intCast(len));
                    try self.buffer.appendSlice(self.allocator, std.mem.asBytes(&big));
                    try self.buffer.append(self.allocator, @bitCast(e.type));
                }
            },
        }

        try self.buffer.appendSlice(self.allocator, e.data);
    }

    pub fn getBytes(self: *Encoder) []const u8 {
        return self.buffer.items;
    }
};

/// Decoder state
pub const Decoder = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, data: []const u8) Decoder {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
        };
    }

    pub fn decode(self: *Decoder) DecodeError!Value {
        if (self.pos >= self.data.len) {
            return DecodeError.InvalidMsgpack;
        }

        const tag = self.data[self.pos];
        self.pos += 1;

        return switch (tag) {
            // Nil
            0xc0 => .nil,

            // Bool
            0xc2 => .{ .boolean = false },
            0xc3 => .{ .boolean = true },

            // Binary
            0xc4 => try self.decodeBin(1),
            0xc5 => try self.decodeBin(2),
            0xc6 => try self.decodeBin(4),

            // Extension
            0xc7 => try self.decodeExtVar(1),
            0xc8 => try self.decodeExtVar(2),
            0xc9 => try self.decodeExtVar(4),
            0xd4 => try self.decodeExtFixed(1),
            0xd5 => try self.decodeExtFixed(2),
            0xd6 => try self.decodeExtFixed(4),
            0xd7 => try self.decodeExtFixed(8),
            0xd8 => try self.decodeExtFixed(16),

            // Float
            0xca => try self.decodeFloat32(),
            0xcb => try self.decodeFloat64(),

            // Unsigned integers
            0xcc => try self.decodeUint8(),
            0xcd => try self.decodeUint16(),
            0xce => try self.decodeUint32(),
            0xcf => try self.decodeUint64(),

            // Signed integers
            0xd0 => try self.decodeInt8(),
            0xd1 => try self.decodeInt16(),
            0xd2 => try self.decodeInt32(),
            0xd3 => try self.decodeInt64(),

            // String
            0xd9 => try self.decodeStr(1),
            0xda => try self.decodeStr(2),
            0xdb => try self.decodeStr(4),

            // Array
            0xdc => try self.decodeArray(2),
            0xdd => try self.decodeArray(4),

            // Map
            0xde => try self.decodeMap(2),
            0xdf => try self.decodeMap(4),

            else => {
                // Positive fixint: 0x00 - 0x7f
                if (tag <= 0x7f) {
                    return .{ .uint = tag };
                }
                // Fixmap: 0x80 - 0x8f
                else if (tag >= 0x80 and tag <= 0x8f) {
                    const len: u4 = @intCast(tag & 0x0f);
                    return try self.decodeMapFixed(len);
                }
                // Fixarray: 0x90 - 0x9f
                else if (tag >= 0x90 and tag <= 0x9f) {
                    const len: u4 = @intCast(tag & 0x0f);
                    return try self.decodeArrayFixed(len);
                }
                // Fixstr: 0xa0 - 0xbf
                else if (tag >= 0xa0 and tag <= 0xbf) {
                    const len: u5 = @intCast(tag & 0x1f);
                    return try self.decodeStrFixed(len);
                }
                // Negative fixint: 0xe0 - 0xff
                else if (tag >= 0xe0) {
                    const val: i8 = @bitCast(tag);
                    return .{ .int = val };
                }

                return DecodeError.InvalidMsgpack;
            },
        };
    }

    fn readByte(self: *Decoder) DecodeError!u8 {
        if (self.pos >= self.data.len) {
            return DecodeError.InvalidMsgpack;
        }
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Decoder, len: usize) DecodeError![]const u8 {
        if (self.pos + len > self.data.len) {
            return DecodeError.InvalidMsgpack;
        }
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    fn readU16BE(self: *Decoder) DecodeError!u16 {
        const bytes = try self.readBytes(2);
        return std.mem.bigToNative(u16, @bitCast(bytes[0..2].*));
    }

    fn readU32BE(self: *Decoder) DecodeError!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.bigToNative(u32, @bitCast(bytes[0..4].*));
    }

    fn readU64BE(self: *Decoder) DecodeError!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.bigToNative(u64, @bitCast(bytes[0..8].*));
    }

    fn decodeBin(self: *Decoder, len_bytes: usize) DecodeError!Value {
        const len = switch (len_bytes) {
            1 => try self.readByte(),
            2 => try self.readU16BE(),
            4 => try self.readU32BE(),
            else => unreachable,
        };
        const data = try self.readBytes(len);
        const copy = try self.allocator.dupe(u8, data);
        return .{ .binary = copy };
    }

    fn decodeExtVar(self: *Decoder, len_bytes: usize) DecodeError!Value {
        const len = switch (len_bytes) {
            1 => try self.readByte(),
            2 => try self.readU16BE(),
            4 => try self.readU32BE(),
            else => unreachable,
        };
        const ext_type: i8 = @bitCast(try self.readByte());
        const data = try self.readBytes(len);
        const copy = try self.allocator.dupe(u8, data);
        return .{ .ext = .{ .type = ext_type, .data = copy } };
    }

    fn decodeExtFixed(self: *Decoder, len: usize) DecodeError!Value {
        const ext_type: i8 = @bitCast(try self.readByte());
        const data = try self.readBytes(len);
        const copy = try self.allocator.dupe(u8, data);
        return .{ .ext = .{ .type = ext_type, .data = copy } };
    }

    fn decodeFloat32(self: *Decoder) DecodeError!Value {
        const bytes = try self.readBytes(4);
        const bits = std.mem.bigToNative(u32, @bitCast(bytes[0..4].*));
        const val: f32 = @bitCast(bits);
        return .{ .float = @floatCast(val) };
    }

    fn decodeFloat64(self: *Decoder) DecodeError!Value {
        const bytes = try self.readBytes(8);
        const bits = std.mem.bigToNative(u64, @bitCast(bytes[0..8].*));
        const val: f64 = @bitCast(bits);
        return .{ .float = val };
    }

    fn decodeUint8(self: *Decoder) DecodeError!Value {
        return .{ .uint = try self.readByte() };
    }

    fn decodeUint16(self: *Decoder) DecodeError!Value {
        return .{ .uint = try self.readU16BE() };
    }

    fn decodeUint32(self: *Decoder) DecodeError!Value {
        return .{ .uint = try self.readU32BE() };
    }

    fn decodeUint64(self: *Decoder) DecodeError!Value {
        return .{ .uint = try self.readU64BE() };
    }

    fn decodeInt8(self: *Decoder) DecodeError!Value {
        const val: i8 = @bitCast(try self.readByte());
        return .{ .int = val };
    }

    fn decodeInt16(self: *Decoder) DecodeError!Value {
        const bytes = try self.readBytes(2);
        const val = std.mem.bigToNative(i16, @bitCast(bytes[0..2].*));
        return .{ .int = val };
    }

    fn decodeInt32(self: *Decoder) DecodeError!Value {
        const bytes = try self.readBytes(4);
        const val = std.mem.bigToNative(i32, @bitCast(bytes[0..4].*));
        return .{ .int = val };
    }

    fn decodeInt64(self: *Decoder) DecodeError!Value {
        const bytes = try self.readBytes(8);
        const val = std.mem.bigToNative(i64, @bitCast(bytes[0..8].*));
        return .{ .int = val };
    }

    fn decodeStrFixed(self: *Decoder, len: u5) DecodeError!Value {
        const data = try self.readBytes(len);
        const copy = try self.allocator.dupe(u8, data);
        return .{ .string = copy };
    }

    fn decodeStr(self: *Decoder, len_bytes: usize) DecodeError!Value {
        const len = switch (len_bytes) {
            1 => try self.readByte(),
            2 => try self.readU16BE(),
            4 => try self.readU32BE(),
            else => unreachable,
        };
        const data = try self.readBytes(len);
        const copy = try self.allocator.dupe(u8, data);
        return .{ .string = copy };
    }

    fn decodeArrayFixed(self: *Decoder, len: u4) DecodeError!Value {
        const arr = try self.allocator.alloc(Value, len);
        for (arr) |*elem| {
            elem.* = try self.decode();
        }
        return .{ .array = arr };
    }

    fn decodeArray(self: *Decoder, len_bytes: usize) DecodeError!Value {
        const len = switch (len_bytes) {
            2 => try self.readU16BE(),
            4 => try self.readU32BE(),
            else => unreachable,
        };
        const arr = try self.allocator.alloc(Value, len);
        for (arr) |*elem| {
            elem.* = try self.decode();
        }
        return .{ .array = arr };
    }

    fn decodeMapFixed(self: *Decoder, len: u4) DecodeError!Value {
        const entries = try self.allocator.alloc(Value.MapEntry, len);
        for (entries) |*entry| {
            entry.key = try self.decode();
            entry.value = try self.decode();
        }
        return .{ .map = entries };
    }

    fn decodeMap(self: *Decoder, len_bytes: usize) DecodeError!Value {
        const len = switch (len_bytes) {
            2 => try self.readU16BE(),
            4 => try self.readU32BE(),
            else => unreachable,
        };
        const entries = try self.allocator.alloc(Value.MapEntry, len);
        for (entries) |*entry| {
            entry.key = try self.decode();
            entry.value = try self.decode();
        }
        return .{ .map = entries };
    }

    pub fn consumed(self: *Decoder) usize {
        return self.pos;
    }
};

/// High-level API: encode a value
pub fn encode(allocator: Allocator, value: Value) EncodeError![]u8 {
    var enc = Encoder.init(allocator);
    errdefer enc.deinit();
    try enc.encode(value);
    return enc.buffer.toOwnedSlice(allocator);
}

/// High-level API: decode a value
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Value {
    var dec = Decoder.init(allocator, data);
    return dec.decode();
}

/// High-level API: decode and return consumed bytes
pub fn decodeSlice(allocator: Allocator, data: []const u8) DecodeError!struct { value: Value, consumed: usize } {
    var dec = Decoder.init(allocator, data);
    const value = try dec.decode();
    return .{ .value = value, .consumed = dec.consumed() };
}

/// Incremental encoding helpers. These write a single value (or a container
/// header) to an existing buffer, allowing callers to stream nested values.
pub fn encodeNil(allocator: Allocator, buffer: *std.ArrayList(u8)) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeNil();
    buffer.* = enc.buffer;
}

pub fn encodeBool(allocator: Allocator, buffer: *std.ArrayList(u8), b: bool) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeBool(b);
    buffer.* = enc.buffer;
}

pub fn encodeInt(allocator: Allocator, buffer: *std.ArrayList(u8), i: i64) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeInt(i);
    buffer.* = enc.buffer;
}

pub fn encodeFloat(allocator: Allocator, buffer: *std.ArrayList(u8), f: f64) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeFloat(f);
    buffer.* = enc.buffer;
}

pub fn encodeString(allocator: Allocator, buffer: *std.ArrayList(u8), s: []const u8) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeString(s);
    buffer.* = enc.buffer;
}

pub fn encodeArrayStart(allocator: Allocator, buffer: *std.ArrayList(u8), len: usize) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeArrayHeader(len);
    buffer.* = enc.buffer;
}

pub fn encodeMapStart(allocator: Allocator, buffer: *std.ArrayList(u8), len: usize) EncodeError!void {
    var enc = Encoder{ .buffer = buffer.*, .allocator = allocator };
    errdefer buffer.* = enc.buffer;
    try enc.encodeMapHeader(len);
    buffer.* = enc.buffer;
}
