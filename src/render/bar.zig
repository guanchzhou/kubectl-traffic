const std = @import("std");

const FULL = "\u{2588}"; // █  (3 UTF-8 bytes)

pub fn render(buf: []u8, value: f64, max: f64, width: usize) ![]u8 {
    const frac = if (max <= 0 or !std.math.isFinite(max) or !std.math.isFinite(value))
        0.0
    else
        std.math.clamp(value / max, 0.0, 1.0);
    const cells: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(width))));
    var w: usize = 0;
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        if (w + FULL.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[w .. w + FULL.len], FULL);
        w += FULL.len;
    }
    return buf[0..w];
}
