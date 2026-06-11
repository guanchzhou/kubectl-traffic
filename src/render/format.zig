const std = @import("std");

pub const Health = enum { good, warn, bad };

pub fn health(success_pct: f64) Health {
    if (success_pct >= 99.9) return .good;
    if (success_pct >= 95.0) return .warn;
    return .bad;
}

pub fn rate(buf: []u8, v: f64) ![]u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{v});
}

pub fn percent(buf: []u8, v: f64) ![]u8 {
    return std.fmt.bufPrint(buf, "{d:.1}%", .{v});
}

pub fn latencyMs(buf: []u8, ms: f64) ![]u8 {
    if (std.math.isNan(ms)) return std.fmt.bufPrint(buf, "-", .{});
    return std.fmt.bufPrint(buf, "{d:.0}ms", .{ms});
}
