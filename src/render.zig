const std = @import("std");
const Editor = @import("editor.zig").Editor;
const Terminal = @import("terminal.zig").Terminal;

pub fn render(ed: *Editor, term: *Terminal) void {
    var ab = std.ArrayList(u8).initCapacity(ed.allocator, 4096) catch return;
    defer ab.deinit(ed.allocator);

    ab.appendSlice(ed.allocator, "\x1b[?25l") catch {}; // Hide cursor
    ab.appendSlice(ed.allocator, "\x1b[H") catch {}; // Move cursor to top-left

    // Reserve 2 rows at bottom: 1 for status bar, 1 for message bar
    const editor_rows = if (term.screen_rows > 2) term.screen_rows - 2 else 1;

    // Draw editor rows
    var y: usize = 0;
    while (y < editor_rows) : (y += 1) {
        const filerow = y + ed.offset_row;
        if (filerow >= ed.rows.items.len) {
            if (filerow == ed.rows.items.len / 2 and ed.rows.items.len == 1 and ed.rows.items[0].len == 0) {
                // Show welcome message centered
                const welcome = "~ zigvim ~ Press i to insert, :q to quit";
                const padding = if (term.screen_cols > welcome.len) (term.screen_cols - welcome.len) / 2 else 0;
                ab.appendSlice(ed.allocator, "\x1b[K") catch {};
                for (0..padding) |_| {
                    ab.append(ed.allocator, ' ') catch {};
                }
                ab.appendSlice(ed.allocator, welcome) catch {};
            } else {
                ab.appendSlice(ed.allocator, "\x1b[K") catch {}; // Clear line
                ab.appendSlice(ed.allocator, "~") catch {};
            }
        } else {
            const row = ed.rows.items[filerow];
            const start = if (ed.offset_col < row.len) ed.offset_col else row.len;
            const end = if (ed.offset_col + term.screen_cols < row.len) ed.offset_col + term.screen_cols else row.len;

            ab.appendSlice(ed.allocator, "\x1b[K") catch {};
            if (start < end) {
                ab.appendSlice(ed.allocator, row[start..end]) catch {};
            }
        }

        ab.appendSlice(ed.allocator, "\r\n") catch {};
    }

    // Draw status bar (inverse video)
    ab.appendSlice(ed.allocator, "\x1b[K") catch {};
    ab.appendSlice(ed.allocator, "\x1b[7m") catch {};

    const filename = ed.filename orelse "[No Name]";
    const modified = if (ed.dirty) " [+]" else "";
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;

    // Mode indicator
    const mode_str = switch (ed.mode) {
        .normal => " NORMAL ",
        .insert => " INSERT ",
        .command => " ",
    };

    const status = std.fmt.bufPrint(&buf1, "{s} {s}{s} - {} lines", .{ mode_str, filename, modified, ed.rows.items.len }) catch "???";
    ab.appendSlice(ed.allocator, status) catch {};

    const rstatus = std.fmt.bufPrint(&buf2, "{}:{}", .{ ed.cursor_row + 1, ed.cursor_col + 1 }) catch "???";
    const padding = if (term.screen_cols > status.len + rstatus.len) term.screen_cols - status.len - rstatus.len else 0;
    for (0..padding) |_| {
        ab.append(ed.allocator, ' ') catch {};
    }
    ab.appendSlice(ed.allocator, rstatus) catch {};

    ab.appendSlice(ed.allocator, "\x1b[0m") catch {}; // Reset formatting
    ab.appendSlice(ed.allocator, "\r\n") catch {};

    // Draw message bar
    ab.appendSlice(ed.allocator, "\x1b[K") catch {};
    if (ed.mode == .command) {
        // In command mode, show the command buffer
        var cmd_buf: [512]u8 = undefined;
        const cmd_str = std.fmt.bufPrint(&cmd_buf, ":{s}", .{ed.cmd_buf.items}) catch ":";
        ab.appendSlice(ed.allocator, cmd_str) catch {};
    } else if (ed.status_msg.len > 0) {
        const msg_len = if (ed.status_msg.len < term.screen_cols) ed.status_msg.len else term.screen_cols;
        ab.appendSlice(ed.allocator, ed.status_msg[0..msg_len]) catch {};
    }

    // Position cursor
    ab.appendSlice(ed.allocator, "\x1b[") catch {};
    const cursor_screen_row = ed.cursor_row - ed.offset_row + 1;
    const cursor_screen_col = ed.cursor_col - ed.offset_col + 1;
    var pos_buf: [64]u8 = undefined;
    const pos = std.fmt.bufPrint(&pos_buf, "{};{}H", .{ cursor_screen_row, cursor_screen_col }) catch unreachable;
    ab.appendSlice(ed.allocator, pos) catch {};

    ab.appendSlice(ed.allocator, "\x1b[?25h") catch {}; // Show cursor

    Terminal.write(ab.items);
}
