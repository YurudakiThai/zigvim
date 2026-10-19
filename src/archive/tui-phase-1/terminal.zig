const std = @import("std");
const posix = std.posix;

pub const Terminal = struct {
    original_termios: ?posix.termios,
    screen_rows: usize,
    screen_cols: usize,
    unread_byte: ?u8,

    pub fn init() !Terminal {
        var term = Terminal{
            .original_termios = null,
            .screen_rows = 24,
            .screen_cols = 80,
            .unread_byte = null,
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
        raw.iflag.IXOFF = false;

        // Output flags
        raw.oflag.OPOST = false;

        // Control flags
        raw.cflag.CSIZE = .CS8;

        // Local flags
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Control characters: VMIN=0, VTIME=1 (100ms timeout)
        // VMIN=0, VTIME=1 means read returns after 100ms even if no byte arrives.
        // This prevents blocking and allows the main loop to check for quit signals.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

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
            // Fallback
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

    /// Read a single byte with a short timeout (uses current VMIN/VTIME settings).
    /// Returns 0 if no byte is available within the timeout.
    fn readByte(self: *Terminal) u8 {
        if (self.unread_byte) |b| {
            self.unread_byte = null;
            return b;
        }
        var buf: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            // On macOS, VMIN=0, VTIME=1 may return WouldBlock on timeout
            if (err == error.WouldBlock or err == error.SystemResources) {
                return 0;
            }
            return 0; // Fallback for any other read error
        };
        if (n == 0) return 0;
        return buf[0];
    }

    /// Read a key press. Returns:
    /// - For printable ASCII: the ASCII code (32-126)
    /// - For special keys: codes 1000+
    /// - For Ctrl keys: the control code (1-26)
    /// - 27: Escape (standalone)
    /// - 13: Enter
    /// - 127: Backspace
    /// - 0: no input (timeout)
    pub fn readKey(self: *Terminal) !u32 {
        const ch = self.readByte();
        if (ch == 0) return 0;

        if (ch == 27) {
            // Escape sequence - try to read more bytes.
            const seq1 = self.readByte();
            if (seq1 == 0) return 27; // Standalone Escape

            const seq2 = self.readByte();
            if (seq2 == 0) {
                // Incomplete sequence. If seq1 is not a valid start of escape,
                // we should treat 27 as Escape and "unread" seq1.
                if (seq1 != '[' and seq1 != 'O' and (seq1 < '0' or seq1 > '9')) {
                    self.unread_byte = seq1;
                    return 27;
                }
                return 27;
            }

            if (seq1 == '[') {
                if (seq2 >= '0' and seq2 <= '9') {
                    const seq3 = self.readByte();
                    if (seq3 == 0) {
                        self.unread_byte = seq2;
                        return 27;
                    }
                    if (seq3 == '~') {
                        return switch (seq2) {
                            '1' => @as(u32, 1000), // Home
                            '4' => @as(u32, 1001), // End
                            '5' => @as(u32, 1002), // Page Up
                            '6' => @as(u32, 1003), // Page Down
                            '7' => @as(u32, 1000), // Home (alternate)
                            '8' => @as(u32, 1001), // End (alternate)
                            else => @as(u32, 27),
                        };
                    }
                    return 27; // Unknown sequence
                } else {
                    return switch (seq2) {
                        'A' => @as(u32, 1004), // Up
                        'B' => @as(u32, 1005), // Down
                        'C' => @as(u32, 1006), // Right
                        'D' => @as(u32, 1007), // Left
                        'H' => @as(u32, 1000), // Home
                        'F' => @as(u32, 1001), // End
                        else => {
                            self.unread_byte = seq2;
                            return 27;
                        },
                    };
                }
            } else if (seq1 == 'O') {
                return switch (seq2) {
                    'H' => @as(u32, 1000), // Home
                    'F' => @as(u32, 1001), // End
                    else => {
                        self.unread_byte = seq2;
                        return 27;
                    },
                };
            }

            // If seq1 is printable, it means user pressed Esc then a char quickly.
            if (seq1 >= 32 and seq1 <= 126) {
                self.unread_byte = seq1;
                return 27;
            }

            return 27;
        }

        return ch;
    }
};