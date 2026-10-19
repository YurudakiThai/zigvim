//! libuv wrapper for zigvim
//!
//! This module provides a Zig-friendly wrapper around libuv for event loop
//! management, I/O operations, and cross-platform abstractions.

const std = @import("std");
const c = @import("c");

pub const Error = error{
    LoopInitFailed,
    LoopRunFailed,
    LoopCloseFailed,
    TimerInitFailed,
    TimerStartFailed,
    AsyncInitFailed,
    AsyncSendFailed,
    IdleInitFailed,
    IdleStartFailed,
    HandleCloseFailed,
};

/// Event loop wrapper
pub const Loop = struct {
    handle: c.uv_loop_t,

    /// Initialize a new event loop
    pub fn init() Error!Loop {
        var loop: Loop = undefined;
        const result = c.uv_loop_init(&loop.handle);
        if (result != 0) {
            return Error.LoopInitFailed;
        }
        return loop;
    }

    /// Close the event loop and free resources
    pub fn deinit(self: *Loop) void {
        _ = c.uv_loop_close(&self.handle);
    }

    /// Run the event loop
    pub fn run(self: *Loop, mode: c_int) Error!void {
        const result = c.uv_run(&self.handle, mode);
        if (result != 0) {
            return Error.LoopRunFailed;
        }
    }

    /// Check if the loop is alive (has active handles or requests)
    pub fn isAlive(self: *Loop) bool {
        return c.uv_loop_alive(&self.handle) != 0;
    }

    /// Stop the event loop
    pub fn stop(self: *Loop) void {
        c.uv_stop(&self.handle);
    }

    /// Get the underlying handle pointer (for passing to C functions)
    pub fn handlePtr(self: *Loop) *c.uv_loop_t {
        return &self.handle;
    }
};

/// Timer handle wrapper
/// Wraps uv_timer_t for delayed callbacks
pub const Timer = struct {
    handle: c.uv_timer_t,
    /// User data stored as opaque pointer
    data: ?*anyopaque = null,
    /// Callback type
    CallbackType: type = void,

    /// Initialize a timer on the given loop
    pub fn init(loop: *Loop) Error!Timer {
        var timer: Timer = undefined;
        const result = c.uv_timer_init(loop.handlePtr(), &timer.handle);
        if (result != 0) {
            return Error.TimerInitFailed;
        }
        return timer;
    }

    /// Start the timer
    /// timeout: initial delay in milliseconds
    /// repeat: repeat interval (0 for one-shot)
    pub fn start(self: *Timer, timeout: u64, repeat: u64, cb: c.uv_timer_cb) Error!void {
        const result = c.uv_timer_start(&self.handle, cb, timeout, repeat);
        if (result != 0) {
            return Error.TimerStartFailed;
        }
    }

    /// Stop the timer
    pub fn stop(self: *Timer) void {
        _ = c.uv_timer_stop(&self.handle);
    }

    /// Set user data
    pub fn setData(self: *Timer, ptr: ?*anyopaque) void {
        self.data = ptr;
        self.handle.data = ptr;
    }

    /// Get user data
    pub fn getData(self: *Timer) ?*anyopaque {
        return self.data;
    }

    /// Close the timer handle
    pub fn close(self: *Timer, close_cb: ?c.uv_close_cb) void {
        c.uv_close(@ptrCast(&self.handle), close_cb);
    }
};

/// Async handle wrapper
/// Used to wake up the event loop from another thread (or from same thread to defer work)
pub const Async = struct {
    handle: c.uv_async_t,
    data: ?*anyopaque = null,

    /// Initialize an async handle on the given loop
    pub fn init(loop: *Loop, cb: c.uv_async_cb) Error!Async {
        var async_handle: Async = undefined;
        const result = c.uv_async_init(loop.handlePtr(), &async_handle.handle, cb);
        if (result != 0) {
            return Error.AsyncInitFailed;
        }
        return async_handle;
    }

    /// Send an async event (wakes up the event loop)
    pub fn send(self: *Async) Error!void {
        const result = c.uv_async_send(&self.handle);
        if (result != 0) {
            return Error.AsyncSendFailed;
        }
    }

    /// Set user data
    pub fn setData(self: *Async, ptr: ?*anyopaque) void {
        self.data = ptr;
        self.handle.data = ptr;
    }

    /// Close the async handle
    pub fn close(self: *Async, close_cb: ?c.uv_close_cb) void {
        c.uv_close(@ptrCast(&self.handle), close_cb);
    }
};

/// Idle handle wrapper
/// Callback runs once per event loop iteration when there's nothing else to do
pub const Idle = struct {
    handle: c.uv_idle_t,
    data: ?*anyopaque = null,

    pub fn init(loop: *Loop) Error!Idle {
        var idle: Idle = undefined;
        const result = c.uv_idle_init(loop.handlePtr(), &idle.handle);
        if (result != 0) {
            return Error.IdleInitFailed;
        }
        return idle;
    }

    pub fn start(self: *Idle, cb: c.uv_idle_cb) Error!void {
        const result = c.uv_idle_start(&self.handle, cb);
        if (result != 0) {
            return Error.IdleStartFailed;
        }
    }

    pub fn stop(self: *Idle) void {
        _ = c.uv_idle_stop(&self.handle);
    }

    pub fn setData(self: *Idle, ptr: ?*anyopaque) void {
        self.data = ptr;
        self.handle.data = ptr;
    }

    pub fn close(self: *Idle, close_cb: ?c.uv_close_cb) void {
        c.uv_close(@ptrCast(&self.handle), close_cb);
    }
};

/// Get libuv version string
pub fn getVersionString() [*:0]const u8 {
    return c.uv_version_string();
}

/// Get libuv version as tuple (major, minor, patch)
pub fn getVersion() struct { major: u32, minor: u32, patch: u32 } {
    const version = c.uv_version();
    return .{
        .major = (version >> 16) & 0xFF,
        .minor = (version >> 8) & 0xFF,
        .patch = version & 0xFF,
    };
}

/// Get the default loop (convenience function)
pub fn getDefaultLoop() *c.uv_loop_t {
    return c.uv_default_loop();
}

/// Run modes for uv_run
pub const RunMode = struct {
    pub const DEFAULT: c_int = c.UV_RUN_DEFAULT;
    pub const ONCE: c_int = c.UV_RUN_ONCE;
    pub const NOWAIT: c_int = c.UV_RUN_NOWAIT;
};

test "version string" {
    const version = getVersionString();
    const len = std.mem.len(version);
    try std.testing.expect(len > 0);
}

test "version tuple" {
    const ver = getVersion();
    try std.testing.expect(ver.major >= 1);
    try std.testing.expect(ver.minor >= 0);
    try std.testing.expect(ver.patch >= 0);
}
