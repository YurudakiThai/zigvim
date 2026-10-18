const std = @import("std");
const posix = std.posix;

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

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var rows = try std.ArrayList([]u8).initCapacity(allocator, 16);
        try rows.append(allocator, try allocator.dupe(u8, ""));

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
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
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

        self.filename = try self.allocator.dupe(u8, filename);
        self.setStatusMsg("Opened {s}, {} lines", .{ filename, self.rows.items.len });
    }

    pub fn saveFile(self: *Editor, io: std.Io) !void {
        if (self.filename == null) {
            self.setStatusMsg("No filename", .{});
            return;
        }

        const filename = self.filename.?;
        const dir = std.Io.Dir.cwd();
        const file = dir.createFile(io, filename, .{}) catch |err| {
            self.setStatusMsg("Error creating file: {}", .{err});
            return;
        };
        defer file.close();

        for (self.rows.items, 0..) |row, i| {
            file.writeAll(io, row) catch |err| {
                self.setStatusMsg("Error writing: {}", .{err});
                return;
            };
            if (i < self.rows.items.len - 1) {
                file.writeAll(io, "\n") catch {};
            }
        }

        self.dirty = false;
        self.setStatusMsg("Saved {} bytes to {s}", .{ self.getTotalBytes(), filename });
    }

    fn getTotalBytes(self: *Editor) usize {
        var total: usize = 0;
        for (self.rows.items) |row| {
            total += row.len + 1; // +1 for newline
        }
        return total;
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
            .home => {
                self.cursor_col = 0;
            },
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
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "Error";
        self.status_msg = msg;
        self.status_msg_time = 0;
    }
};
