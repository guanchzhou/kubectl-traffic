const std = @import("std");
const fmtmod = @import("render_format");
const spark = @import("render_sparkline");
const bar = @import("render_bar");

test "rate formatting" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12.4", try fmtmod.rate(&buf, 12.43));
    try std.testing.expectEqualStrings("0.0", try fmtmod.rate(&buf, 0));
}

test "latency formatting ms" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("42ms", try fmtmod.latencyMs(&buf, 42.0));
    try std.testing.expectEqualStrings("-", try fmtmod.latencyMs(&buf, std.math.nan(f64)));
}

test "health thresholds" {
    try std.testing.expectEqual(fmtmod.Health.good, fmtmod.health(99.95));
    try std.testing.expectEqual(fmtmod.Health.warn, fmtmod.health(98.5));
    try std.testing.expectEqual(fmtmod.Health.bad, fmtmod.health(90.0));
}

test "sparkline maps to 8 levels" {
    const vals = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var buf: [64]u8 = undefined;
    const s = try spark.render(&buf, &vals);
    try std.testing.expect(std.mem.startsWith(u8, s, "\u{2581}")); // lowest -> ▁
    try std.testing.expect(std.mem.endsWith(u8, s, "\u{2588}")); // highest -> █
}

test "bar scales to width by max" {
    var buf: [32]u8 = undefined;
    const b = try bar.render(&buf, 5.0, 10.0, 8); // half of 8 cells
    try std.testing.expectEqual(@as(usize, 4 * 3), b.len); // 4 full blocks (each █ is 3 UTF-8 bytes)
}
