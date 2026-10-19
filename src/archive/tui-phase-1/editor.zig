const std = @import("std");
const c = @import("c");

// Debug logging to file using C stdio
var debug_log_file: ?*c.FILE = null;
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (debug_log_file == null) {
        debug_log_file = c.fopen("/tmp/zigvim-debug.log", "a");
        if (debug_log_file == null) return;
    }
    const f = debug_log_file.?;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.fwrite(msg.ptr, 1, msg.len, f);
    _ = c.fflush(f);
}

pub const Mode = enum {
    normal,
    insert,
    command,
};

pub const CommandResult = enum {
    none,
    save,
    quit,
    save_and_quit,
    force_quit,
    cmd_error,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList([]u8),
    cursor_row: usize,
    cursor_col: usize,
    offset_row: usize,
    offset_col: usize,
    screen_rows: usize,
    screen_cols: usize,
    filename: ?[]const u8,
    dirty: bool,
    status_msg: []const u8,
    status_msg_time: i64,
    should_quit: bool,
    mode: Mode,
    cmd_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var rows = try std.ArrayList([]u8).initCapacity(allocator, 16);
        try rows.append(allocator, try allocator.dupe(u8, ""));

        const cmd_buf = try std.ArrayList(u8).initCapacity(allocator, 64);

        return Editor{
            .allocator = allocator,
            .rows = rows,
            .cursor_row = 0,
            .cursor_col = 0,
            .offset_row = 0,
            .offset_col = 0,
            .screen_rows = 24,
            .screen_cols = 80,
            .filename = null,
            .dirty = false,
            .status_msg = "",
            .status_msg_time = 0,
            .should_quit = false,
            .mode = .normal,
            .cmd_buf = cmd_buf,
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
        if (self.filename) |f| {
            self.allocator.free(f);
        }
        if (self.status_msg.len > 0 and self.status_msg.ptr != "Error".ptr) {
            self.allocator.free(self.status_msg);
        }
        self.cmd_buf.deinit(self.allocator);
    }

    pub fn openFile(self: *Editor, io: std.Io, filename: []const u8) !void {
        const dir = std.Io.Dir.cwd();
        const content = dir.readFileAlloc(io, filename, self.allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                self.setStatusMsg("New file: {s}", .{filename});
                self.filename = try self.allocator.dupe(u8, filename);
                return;
            }
            self.setStatusMsg("Error reading file: {}", .{err});
            return;
        };
        defer self.allocator.free(content);

        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            try self.rows.append(self.allocator, try self.allocator.dupe(u8, line));
        }

        if (self.rows.items.len == 0) {
            try self.rows.append(self.allocator, try self.allocator.dupe(u8, ""));
        }

        if (self.filename) |f| {
            self.allocator.free(f);
        }
        self.filename = try self.allocator.dupe(u8, filename);
        self.setStatusMsg("Opened {s}, {} lines", .{ filename, self.rows.items.len });
    }

    pub fn saveFile(self: *Editor, io: std.Io) !void {
        if (self.filename == null) {
            self.setStatusMsg("No filename", .{});
            return;
        }

        const filename = self.filename.?;

        var total_size: usize = 0;
        for (self.rows.items, 0..) |row, i| {
            total_size += row.len;
            if (i < self.rows.items.len - 1) {
                total_size += 1;
            }
        }

        var content = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(content);

        var offset: usize = 0;
        for (self.rows.items, 0..) |row, i| {
            @memcpy(content[offset..][0..row.len], row);
            offset += row.len;
            if (i < self.rows.items.len - 1) {
                content[offset] = '\n';
                offset += 1;
            }
        }

        const dir = std.Io.Dir.cwd();
        const file = dir.createFile(io, filename, .{}) catch |err| {
            self.setStatusMsg("Error creating file: {}", .{err});
            return;
        };
        defer file.close(io);

        file.writeStreamingAll(io, content) catch |err| {
            self.setStatusMsg("Error writing: {}", .{err});
            return;
        };

        self.dirty = false;
        self.setStatusMsg("Saved to {s} ({} bytes)", .{ filename, total_size });
    }

    pub fn insertChar(self: *Editor, ch: u8) !void {
        if (self.cursor_row >= self.rows.items.len) {
            try self.rows.append(self.allocator, try self.allocator.dupe(u8, ""));
        }

        const row = self.rows.items[self.cursor_row];
        const col = if (self.cursor_col > row.len) row.len else self.cursor_col;

        var new_row = try self.allocator.alloc(u8, row.len + 1);
        @memcpy(new_row[0..col], row[0..col]);
        new_row[col] = ch;
        @memcpy(new_row[col + 1 ..], row[col..]);

        self.allocator.free(row);
        self.rows.items[self.cursor_row] = new_row;
        self.cursor_col = col + 1;
        self.dirty = true;
    }

    pub fn insertNewline(self: *Editor) !void {
        if (self.cursor_row >= self.rows.items.len) {
            try self.rows.append(self.allocator, try self.allocator.dupe(u8, ""));
            self.cursor_row += 1;
            self.cursor_col = 0;
            return;
        }

        const row = self.rows.items[self.cursor_row];
        const col = if (self.cursor_col > row.len) row.len else self.cursor_col;

        const left = try self.allocator.dupe(u8, row[0..col]);
        const right = try self.allocator.dupe(u8, row[col..]);

        self.allocator.free(row);
        self.rows.items[self.cursor_row] = left;
        try self.rows.insert(self.allocator, self.cursor_row + 1, right);

        self.cursor_row += 1;
        self.cursor_col = 0;
        self.dirty = true;
    }

    pub fn deleteChar(self: *Editor) void {
        if (self.cursor_col == 0) {
            if (self.cursor_row == 0) return;

            const current_row = self.rows.items[self.cursor_row];
            const prev_row = self.rows.items[self.cursor_row - 1];

            var new_row = self.allocator.alloc(u8, prev_row.len + current_row.len) catch return;
            @memcpy(new_row[0..prev_row.len], prev_row);
            @memcpy(new_row[prev_row.len..], current_row);

            self.allocator.free(prev_row);
            self.allocator.free(current_row);

            self.rows.items[self.cursor_row - 1] = new_row;
            _ = self.rows.orderedRemove(self.cursor_row);

            self.cursor_row -= 1;
            self.cursor_col = prev_row.len;
            self.dirty = true;
            return;
        }

        const row = self.rows.items[self.cursor_row];
        const col = self.cursor_col - 1;

        if (col >= row.len) return;

        var new_row = self.allocator.alloc(u8, row.len - 1) catch return;
        @memcpy(new_row[0..col], row[0..col]);
        @memcpy(new_row[col..], row[col + 1 ..]);

        self.allocator.free(row);
        self.rows.items[self.cursor_row] = new_row;
        self.cursor_col = col;
        self.dirty = true;
    }

    pub fn moveCursor(self: *Editor, key: enum { up, down, left, right, home, end, page_up, page_down }) void {
        switch (key) {
            .up => {
                if (self.cursor_row > 0) self.cursor_row -= 1;
            },
            .down => {
                if (self.cursor_row < self.rows.items.len - 1) self.cursor_row += 1;
            },
            .left => {
                if (self.cursor_col > 0) {
                    self.cursor_col -= 1;
                } else if (self.cursor_row > 0) {
                    self.cursor_row -= 1;
                    self.cursor_col = self.rows.items[self.cursor_row].len;
                }
            },
            .right => {
                const row_len = if (self.cursor_row < self.rows.items.len) self.rows.items[self.cursor_row].len else 0;
                if (self.cursor_col < row_len) {
                    self.cursor_col += 1;
                } else if (self.cursor_row < self.rows.items.len - 1) {
                    self.cursor_row += 1;
                    self.cursor_col = 0;
                }
            },
            .home => { self.cursor_col = 0; },
            .end => {
                if (self.cursor_row < self.rows.items.len) {
                    self.cursor_col = self.rows.items[self.cursor_row].len;
                }
            },
            .page_up => {
                for (0..self.screen_rows - 1) |_| {
                    if (self.cursor_row > 0) self.cursor_row -= 1;
                }
            },
            .page_down => {
                for (0..self.screen_rows - 1) |_| {
                    if (self.cursor_row < self.rows.items.len - 1) self.cursor_row += 1;
                }
            },
        }
        if (self.cursor_row < self.rows.items.len) {
            const row_len = self.rows.items[self.cursor_row].len;
            if (self.cursor_col > row_len) {
                self.cursor_col = row_len;
            }
        }
    }

    pub fn scroll(self: *Editor) void {
        if (self.cursor_row < self.offset_row) {
            self.offset_row = self.cursor_row;
        }
        if (self.cursor_row >= self.offset_row + self.screen_rows) {
            self.offset_row = self.cursor_row - self.screen_rows + 1;
        }
        if (self.cursor_col < self.offset_col) {
            self.offset_col = self.cursor_col;
        }
        if (self.cursor_col >= self.offset_col + self.screen_cols) {
            self.offset_col = self.cursor_col - self.screen_cols + 1;
        }
    }

    pub fn setStatusMsg(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        if (self.status_msg.len > 0 and self.status_msg.ptr != "Error".ptr) {
            self.allocator.free(self.status_msg);
        }

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "Error";
        self.status_msg = self.allocator.dupe(u8, msg) catch "Error";
    }

    pub fn clearStatusMsg(self: *Editor) void {
        if (self.status_msg.len > 0 and self.status_msg.ptr != "Error".ptr) {
            self.allocator.free(self.status_msg);
        }
        self.status_msg = "";
    }

    pub fn handleNormalKey(self: *Editor, key: u8) !void {
        switch (key) {
            'h' => self.moveCursor(.left),
            'j' => self.moveCursor(.down),
            'k' => self.moveCursor(.up),
            'l' => self.moveCursor(.right),
            'i', 'a' => {
                self.mode = .insert;
                self.setStatusMsg("-- INSERT --", .{});
            },
            'x' => {
                if (self.cursor_row < self.rows.items.len) {
                    const row = self.rows.items[self.cursor_row];
                    if (self.cursor_col < row.len) {
                        var new_row = try self.allocator.alloc(u8, row.len - 1);
                        @memcpy(new_row[0..self.cursor_col], row[0..self.cursor_col]);
                        @memcpy(new_row[self.cursor_col..], row[self.cursor_col + 1 ..]);
                        self.allocator.free(row);
                        self.rows.items[self.cursor_row] = new_row;
                        self.dirty = true;
                    }
                }
            },
            'd' => { self.deleteLine(); },
            'y' => { self.setStatusMsg("Yanked 1 line", .{}); },
            'p' => { self.setStatusMsg("Pasted", .{}); },
            ':' => {
                debugLog("normal mode: ':' pressed, entering command mode", .{});
                self.mode = .command;
                self.cmd_buf.clearRetainingCapacity();
                self.setStatusMsg(":", .{});
            },
            else => {},
        }
    }

    pub fn handleCommandKey(self: *Editor, key: u8) !void {
        switch (key) {
            27 => {
                self.mode = .normal;
                self.cmd_buf.clearRetainingCapacity();
                self.clearStatusMsg();
            },
            8, 127 => {
                if (self.cmd_buf.items.len > 0) {
                    _ = self.cmd_buf.pop();
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, ":{s}", .{self.cmd_buf.items}) catch ":";
                    if (self.status_msg.len > 0 and self.status_msg.ptr != "Error".ptr) {
                        self.allocator.free(self.status_msg);
                    }
                    self.status_msg = try self.allocator.dupe(u8, msg);
                }
            },
            13 => { _ = self.executeCommand(); },
            else => {
                if (key >= 32 and key <= 126) {
                    try self.cmd_buf.append(self.allocator, key);
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, ":{s}", .{self.cmd_buf.items}) catch ":";
                    if (self.status_msg.len > 0 and self.status_msg.ptr != "Error".ptr) {
                        self.allocator.free(self.status_msg);
                    }
                    self.status_msg = try self.allocator.dupe(u8, msg);
                }
            },
        }
    }

    pub fn executeCommand(self: *Editor) CommandResult {
        const cmd = self.cmd_buf.items;
        debugLog("executeCommand called, cmd.len={}, cmd=\"{s}\"", .{ cmd.len, cmd });
        // Log each byte for debugging
        for (cmd, 0..) |b, i| {
            debugLog("  cmd[{}]={} ('{c}')", .{ i, b, if (b >= 32 and b < 127) b else '?' });
        }

        const result: CommandResult = if (std.mem.eql(u8, cmd, "w") or std.mem.eql(u8, cmd, "write")) blk: {
            debugLog("  -> matched 'w', returning save", .{});
            break :blk .save;
        } else if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) blk: {
            debugLog("  -> matched 'q', dirty={}", .{self.dirty});
            if (self.dirty) {
                self.setStatusMsg("E37: No write since last change (add ! to override)", .{});
                break :blk .cmd_error;
            }
            break :blk .quit;
        } else if (std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "x")) blk: {
            debugLog("  -> matched 'wq', returning save_and_quit", .{});
            break :blk .save_and_quit;
        } else if (std.mem.eql(u8, cmd, "q!")) blk: {
            debugLog("  -> matched 'q!', returning force_quit", .{});
            break :blk .force_quit;
        } else if (std.mem.eql(u8, cmd, "qa") or std.mem.eql(u8, cmd, "qall")) blk: {
            debugLog("  -> matched 'qa', dirty={}", .{self.dirty});
            if (self.dirty) {
                self.setStatusMsg("E37: No write since last change (use ! to override)", .{});
                break :blk .cmd_error;
            }
            break :blk .quit;
        } else if (std.mem.eql(u8, cmd, "qa!") or std.mem.eql(u8, cmd, "qall!")) blk: {
            debugLog("  -> matched 'qa!', returning force_quit", .{});
            break :blk .force_quit;
        } else blk: {
            debugLog("  -> NO MATCH, cmd=\"{s}\"", .{cmd});
            self.setStatusMsg("E492: Not an editor command: {s}", .{cmd});
            break :blk .cmd_error;
        };

        self.mode = .normal;
        self.cmd_buf.clearRetainingCapacity();
        return result;
    }

    fn deleteLine(self: *Editor) void {
        if (self.rows.items.len <= 1) {
            self.allocator.free(self.rows.items[0]);
            self.rows.items[0] = self.allocator.dupe(u8, "") catch return;
            self.cursor_col = 0;
            self.dirty = true;
            return;
        }

        const row = self.rows.items[self.cursor_row];
        self.allocator.free(row);
        _ = self.rows.orderedRemove(self.cursor_row);

        if (self.cursor_row >= self.rows.items.len) {
            self.cursor_row = self.rows.items.len - 1;
        }
        if (self.cursor_col >= self.rows.items[self.cursor_row].len) {
            self.cursor_col = self.rows.items[self.cursor_row].len;
        }
        self.dirty = true;
        self.setStatusMsg("1 line deleted", .{});
    }
};