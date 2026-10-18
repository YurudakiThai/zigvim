const std = @import("std");
const Editor = @import("editor.zig").Editor;
const Terminal = @import("terminal.zig").Terminal;

pub fn render(editor: *Editor, terminal: *Terminal) void {
    var ab = std.ArrayList(u8).initCapacity(editor.allocator, 256) catch return;
    defer ab.deinit(editor.allocator);

    ab.appendSlice(editor.allocator, "\x1b[?25l") catch {}; // Hide cursor
    ab.appendSlice(editor.allocator, "\x1b[H") catch {}; // Move cursor to top-left

    // Draw rows
    for (0..terminal.screen_rows) |y| {
        const filerow = y + editor.offset_row;
        if (filerow >= editor.rows.items.len) {
            if (filerow == editor.rows.items.len / 2 and editor.rows.items.len == 1) {
                // Show welcome message
                const welcome = "zigvim -- type :q to quit";
                const padding = if (terminal.screen_cols > welcome.len) (terminal.screen_cols - welcome.len) / 2 else 0;
                ab.appendSlice(editor.allocator, "\x1b[K") catch {};
                ab.appendSlice(editor.allocator, "\x1b[") catch {};
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{}G", .{padding}) catch unreachable;
                ab.appendSlice(editor.allocator, s) catch {};
                ab.appendSlice(editor.allocator, welcome) catch {};
            } else {
                ab.appendSlice(editor.allocator, "\x1b[K") catch {}; // Clear line
            }
        } else {
            const row = editor.rows.items[filerow];
            const start = if (editor.offset_col < row.len) editor.offset_col else row.len;
            const end = if (editor.offset_col + terminal.screen_cols < row.len) editor.offset_col + terminal.screen_cols else row.len;

            ab.appendSlice(editor.allocator, "\x1b[K") catch {};
            if (start < end) {
                ab.appendSlice(editor.allocator, row[start..end]) catch {};
            }
        }

        if (y < terminal.screen_rows - 1) {
            ab.appendSlice(editor.allocator, "\r\n") catch {};
        }
    }

    // Draw status bar
    ab.appendSlice(editor.allocator, "\x1b[K") catch {};
    ab.appendSlice(editor.allocator, "\x1b[7m") catch {}; // Inverse video

    const filename = editor.filename orelse "[No Name]";
    const modified = if (editor.dirty) " [+]" else "";
    var buf: [256]u8 = undefined;
    const status = std.fmt.bufPrint(&buf, " {s}{s} - {} lines ", .{ filename, modified, editor.rows.items.len }) catch "???";
    ab.appendSlice(editor.allocator, status) catch {};

    const rstatus = std.fmt.bufPrint(&buf, " {}/{} ", .{ editor.cursor_row + 1, editor.rows.items.len }) catch "???";
    const padding = if (terminal.screen_cols > status.len + rstatus.len) terminal.screen_cols - status.len - rstatus.len else 0;
    for (0..padding) |_| {
        ab.append(editor.allocator, ' ') catch {};
    }
    ab.appendSlice(editor.allocator, rstatus) catch {};

    ab.appendSlice(editor.allocator, "\x1b[0m") catch {}; // Reset formatting
    ab.appendSlice(editor.allocator, "\r\n") catch {};

    // Draw message bar
    ab.appendSlice(editor.allocator, "\x1b[K") catch {};
    const msg_len = if (editor.status_msg.len < terminal.screen_cols) editor.status_msg.len else terminal.screen_cols;
    if (msg_len > 0) {
        ab.appendSlice(editor.allocator, editor.status_msg[0..msg_len]) catch {};
    }

    // Position cursor
    ab.appendSlice(editor.allocator, "\x1b[") catch {};
    const cursor_screen_row = editor.cursor_row - editor.offset_row + 1;
    const cursor_screen_col = editor.cursor_col - editor.offset_col + 1;
    const pos = std.fmt.bufPrint(&buf, "{};{}H", .{ cursor_screen_row, cursor_screen_col }) catch unreachable;
    ab.appendSlice(editor.allocator, pos) catch {};

    ab.appendSlice(editor.allocator, "\x1b[?25h") catch {}; // Show cursor

    Terminal.write(ab.items);
}
