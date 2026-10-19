/// Raw ANSI terminal backend.
///
/// Uses POSIX syscalls directly (std.c.write / std.posix.read / poll) to
/// avoid the std.Io async abstraction, which is correct for terminal
/// manipulation: ANSI escapes are fire-and-forget synchronous writes to a
/// character device, not async file I/O.
const std = @import("std");
const line = @import("render_line");

pub const Key = enum { quit, none };

// File-scope globals for panic/signal restore.  Written only in init(), cleared
// in deinit() so double-restore is a no-op.
var g_active: bool = false;
var g_orig_termios: ?std.posix.termios = null;
var g_in_fd: std.posix.fd_t = undefined;

/// Best-effort terminal restore called from the custom panic handler.
/// Safe to call when no TUI is active (g_active == false → returns immediately).
pub fn restoreOnPanic() void {
    if (!g_active) return;
    // Show cursor + leave alt screen.
    _ = std.c.write(std.posix.STDOUT_FILENO, "\x1b[?25h\x1b[?1049l", 14);
    if (g_orig_termios) |o| std.posix.tcsetattr(g_in_fd, .FLUSH, o) catch {};
    g_active = false;
}

fn colorCode(c: line.Color) []const u8 {
    return switch (c) {
        .default => "39",
        .dim => "2",
        .green => "32",
        .yellow => "33",
        .red => "31",
        .cyan => "36",
    };
}

fn writeAllRaw(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

/// Print a single frame to stdout in plain mode (no alt-screen, no raw mode).
/// Safe for non-tty/piped output. Used by --once.
pub fn printFrame(graph_lines: []const line.StyledLine, table_lines: []const line.StyledLine, title: []const u8) !void {
    const fd = std.posix.STDOUT_FILENO;
    try writeAllRaw(fd, title);
    try writeAllRaw(fd, "\n\n");
    for (graph_lines) |ln| {
        for (ln.spans) |s| {
            try writeAllRaw(fd, "\x1b[");
            try writeAllRaw(fd, colorCode(s.color));
            try writeAllRaw(fd, "m");
            try writeAllRaw(fd, s.text);
            try writeAllRaw(fd, "\x1b[0m");
            try writeAllRaw(fd, " ");
        }
        try writeAllRaw(fd, "\n");
    }
    try writeAllRaw(fd, "\n");
    for (table_lines) |ln| {
        for (ln.spans) |s| {
            try writeAllRaw(fd, "\x1b[");
            try writeAllRaw(fd, colorCode(s.color));
            try writeAllRaw(fd, "m");
            try writeAllRaw(fd, s.text);
            try writeAllRaw(fd, "\x1b[0m");
            try writeAllRaw(fd, " ");
        }
        try writeAllRaw(fd, "\n");
    }
}

pub const Tui = struct {
    out_fd: std.posix.fd_t,
    in_fd: std.posix.fd_t,
    orig_termios: ?std.posix.termios = null,

    pub fn init() !Tui {
        var t = Tui{
            .out_fd = std.posix.STDOUT_FILENO,
            .in_fd = std.posix.STDIN_FILENO,
        };
        // Enable raw mode on stdin so single keypresses arrive without Enter / echo.
        if (std.c.isatty(t.in_fd) != 0) {
            const orig = try std.posix.tcgetattr(t.in_fd);
            t.orig_termios = orig;
            var raw = orig;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            // Disable signal generation: Ctrl-C arrives as byte 0x03 instead of
            // SIGINT, so the quit path in poll() handles it and deinit() always runs.
            raw.lflag.ISIG = false;
            // VMIN=0, VTIME=0 → non-blocking single-byte reads
            raw.cc[@backingInt(std.posix.V.MIN)] = 0;
            raw.cc[@backingInt(std.posix.V.TIME)] = 0;
            try std.posix.tcsetattr(t.in_fd, .FLUSH, raw);
            // Arm the file-scope globals so the panic handler can restore state.
            g_orig_termios = orig;
            g_in_fd = t.in_fd;
            g_active = true;
        }
        try t.writeAll("\x1b[?1049h\x1b[?25l"); // alt screen + hide cursor
        return t;
    }

    pub fn deinit(self: *Tui) void {
        // Clear the panic-restore flag first so that, if writeAll somehow panics,
        // the panic handler still has a consistent view.
        g_active = false;
        self.writeAll("\x1b[?25h\x1b[?1049l") catch {}; // show cursor + leave alt screen
        if (self.orig_termios) |orig| {
            std.posix.tcsetattr(self.in_fd, .FLUSH, orig) catch {};
        }
    }

    fn writeAll(self: *Tui, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = std.c.write(self.out_fd, bytes.ptr + written, bytes.len - written);
            if (n < 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    /// Non-blocking poll: wait up to timeout_ms for a keypress.
    /// Returns .quit on 'q' or Ctrl-C (0x03), else .none.
    pub fn poll(self: *Tui, timeout_ms: u64) !Key {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.in_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i32))))) catch 0;
        if (n == 0) return .none;
        var buf: [8]u8 = undefined;
        const r = std.posix.read(self.in_fd, &buf) catch return .none;
        if (r == 0) return .none;
        for (buf[0..r]) |c| {
            if (c == 'q' or c == 0x03) return .quit;
        }
        return .none;
    }

    fn paintLines(self: *Tui, lines_slice: []const line.StyledLine) !void {
        for (lines_slice) |ln| {
            for (ln.spans) |s| {
                try self.writeAll("\x1b[");
                try self.writeAll(colorCode(s.color));
                try self.writeAll("m");
                try self.writeAll(s.text);
                try self.writeAll("\x1b[0m");
                try self.writeAll(" ");
            }
            try self.writeAll("\r\n");
        }
    }

    pub fn paint(
        self: *Tui,
        graph_lines: []const line.StyledLine,
        table_lines: []const line.StyledLine,
        title: []const u8,
    ) !void {
        try self.writeAll("\x1b[2J\x1b[H"); // clear screen + cursor home
        try self.writeAll(title);
        try self.writeAll("\r\n\r\n");
        try self.paintLines(graph_lines);
        try self.writeAll("\r\n");
        try self.paintLines(table_lines);
    }
};
