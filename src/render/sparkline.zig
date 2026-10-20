const std = @import("std");

const levels = [_][]const u8{
    "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
    "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}",
};

pub fn render(buf: []u8, vals: []const f64) ![]u8 {
    if (vals.len == 0) return buf[0..0];
    var lo: f64 = vals[0];
    var hi: f64 = vals[0];
    for (vals) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const span = hi - lo;
    var w: usize = 0;
    for (vals) |v| {
        const lvl: usize = if (span <= 0 or !std.math.isFinite(span) or !std.math.isFinite(v))
            0
        else
            @intFromFloat(@round((v - lo) / span * 7.0));
        const g = levels[std.math.clamp(lvl, @as(usize, 0), @as(usize, 7))];
        if (w + g.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[w .. w + g.len], g);
        w += g.len;
    }
    return buf[0..w];
}
