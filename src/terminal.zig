const std = @import("std");
const posix = std.posix;

pub const Terminal = struct {
    original_termios: ?posix.termios,
    screen_rows: usize,
    screen_cols: usize,

    pub fn init() !Terminal {
        var term = Terminal{
            .original_termios = null,
            .screen_rows = 24,
            .screen_cols = 80,
        };
        try term.getWinSize();
        return term;
    }

    pub fn enableRawMode(self: *Terminal) !void {
        const fd = std.posix.STDIN_FILENO;
        var raw = try posix.tcgetattr(fd);
        self.original_termios = raw;

        // Input flags
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        // Output flags
        raw.oflag.OPOST = false;

        // Control flags
        raw.cflag.CSIZE = .CS8;

        // Local flags
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Control characters
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .NOW, raw);
    }

    pub fn disableRawMode(self: *Terminal) !void {
        if (self.original_termios) |orig| {
            const fd = std.posix.STDIN_FILENO;
            try posix.tcsetattr(fd, .NOW, orig);
        }
    }

    pub fn getWinSize(self: *Terminal) !void {
        const fd = std.posix.STDOUT_FILENO;
        var ws: posix.winsize = undefined;
        const rc = std.c.ioctl(fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != -1 and ws.col != 0) {
            self.screen_cols = ws.col;
            self.screen_rows = ws.row;
        } else {
            // Fallback: try to query cursor position
            self.screen_cols = 80;
            self.screen_rows = 24;
        }
    }

    pub fn clearScreen() void {
        write("\x1b[2J");
        write("\x1b[H");
    }

    pub fn setCursorPos(row: usize, col: usize) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row + 1, col + 1 }) catch return;
        write(s);
    }

    pub fn hideCursor() void {
        write("\x1b[?25l");
    }

    pub fn showCursor() void {
        write("\x1b[?25h");
    }

    pub fn write(s: []const u8) void {
        _ = std.c.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
    }

    pub fn readKey() !u32 {
        var buf: [1]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) return 0;

        const ch = buf[0];

        if (ch == 27) {
            // Escape sequence
            var seq: [3]u8 = undefined;
            const n1 = posix.read(posix.STDIN_FILENO, seq[0..1]) catch 0;
            if (n1 == 0) return 27;
            const n2 = posix.read(posix.STDIN_FILENO, seq[1..2]) catch 0;
            if (n2 == 0) return 27;

            if (seq[0] == '[') {
                if (seq[1] >= '0' and seq[1] <= '9') {
                    const n3 = posix.read(posix.STDIN_FILENO, seq[2..3]) catch 0;
                    if (n3 == 0) return 27;
                    if (seq[2] == '~') {
                        return switch (seq[1]) {
                            '1' => @as(u32, 1000), // Home
                            '4' => @as(u32, 1001), // End
                            '5' => @as(u32, 1002), // Page Up
                            '6' => @as(u32, 1003), // Page Down
                            '7' => @as(u32, 1000), // Home (alternate)
                            '8' => @as(u32, 1001), // End (alternate)
                            else => @as(u32, 27),
                        };
                    }
                } else {
                    return switch (seq[1]) {
                        'A' => @as(u32, 1004), // Up
                        'B' => @as(u32, 1005), // Down
                        'C' => @as(u32, 1006), // Right
                        'D' => @as(u32, 1007), // Left
                        'H' => @as(u32, 1000), // Home
                        'F' => @as(u32, 1001), // End
                        else => @as(u32, 27),
                    };
                }
            } else if (seq[0] == 'O') {
                return switch (seq[1]) {
                    'H' => @as(u32, 1000), // Home
                    'F' => @as(u32, 1001), // End
                    else => @as(u32, 27),
                };
            }
            return 27;
        }

        return ch;
    }
};
