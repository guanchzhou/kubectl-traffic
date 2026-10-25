const std = @import("std");
const fmtmod = @import("render_format");

pub const Color = enum { default, dim, green, yellow, red, cyan };

pub fn colorForHealth(h: fmtmod.Health) Color {
    return switch (h) {
        .good => .green,
        .warn => .yellow,
        .bad => .red,
    };
}

/// Upper bound in bytes for any single span written to the terminal.
pub const max_span_len: usize = 1024;

/// Copy `src` into `dst`, replacing C0 controls, DEL, C1 controls
/// (U+0080..U+009F) and invalid UTF-8 with '?', so label text from Prometheus
/// cannot inject terminal escape sequences. Truncates at a code point boundary
/// when `dst` is full.
pub fn sanitizeInto(dst: []u8, src: []const u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < src.len and w < dst.len) {
        const c = src[i];
        if (c < 0x80) {
            dst[w] = if (c < 0x20 or c == 0x7f) '?' else c;
            w += 1;
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
        const cp: ?u21 = if (n != 0 and i + n <= src.len)
            std.unicode.utf8Decode(src[i .. i + n]) catch null
        else
            null;
        if (cp == null or cp.? <= 0x9f) {
            dst[w] = '?';
            w += 1;
            i += if (cp == null) 1 else n;
            continue;
        }
        if (w + n > dst.len) break;
        @memcpy(dst[w .. w + n], src[i .. i + n]);
        w += n;
        i += n;
    }
    return dst[0..w];
}

/// Owned sanitized copy of `src`, at most `cap` bytes.
pub fn sanitizeAlloc(a: std.mem.Allocator, src: []const u8, cap: usize) ![]u8 {
    const buf = try a.alloc(u8, @min(src.len, cap));
    const out = sanitizeInto(buf, src);
    if (out.len == buf.len) return buf;
    defer a.free(buf);
    return a.dupe(u8, out);
}

pub const Span = struct {
    text: []const u8, // owned
    color: Color = .default,
};

pub const StyledLine = struct {
    spans: []Span, // owned

    pub fn plainText(self: StyledLine, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        for (self.spans) |s| try out.appendSlice(allocator, s.text);
        return out.toOwnedSlice(allocator);
    }
};
