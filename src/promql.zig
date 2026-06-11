const std = @import("std");

/// Escape a PromQL label value (backslash and double-quote). Caller owns result.
pub fn escape(allocator: std.mem.Allocator, v: []const u8) ![]u8 {
    var extra: usize = 0;
    for (v) |c| {
        if (c == '\\' or c == '"') extra += 1;
    }
    if (extra == 0) return allocator.dupe(u8, v);
    var buf = try allocator.alloc(u8, v.len + extra);
    var i: usize = 0;
    for (v) |c| {
        if (c == '\\' or c == '"') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    return buf;
}

pub const Direction = enum { inbound, outbound };

fn selfRole(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "destination", // we are the destination; peers are the sources
        .outbound => "source",
    };
}
fn reporter(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "destination",
        .outbound => "source",
    };
}
fn peerLabel(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "source_workload, source_workload_namespace",
        .outbound => "destination_workload, destination_workload_namespace",
    };
}

/// Selector for the SELF workload side, with both workload and namespace escaped.
fn selector(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const ew = try escape(allocator, workload);
    defer allocator.free(ew);
    const en = try escape(allocator, ns);
    defer allocator.free(en);
    const role = selfRole(dir);
    return std.fmt.allocPrint(
        allocator,
        "reporter=\"{s}\",{s}_workload=\"{s}\",{s}_workload_namespace=\"{s}\"",
        .{ reporter(dir), role, ew, role, en },
    );
}

pub fn rate(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}) (rate(istio_requests_total{{{s}}}[1m]))",
        .{ peerLabel(dir), sel },
    );
}

pub fn errorRate(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}) (rate(istio_requests_total{{{s},response_code=~\"5..\"}}[1m]))",
        .{ peerLabel(dir), sel },
    );
}

pub fn latency(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8, quantile: f64) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "histogram_quantile({d}, sum by (le, {s}) (rate(istio_request_duration_milliseconds_bucket{{{s}}}[1m])))",
        .{ quantile, peerLabel(dir), sel },
    );
}

pub fn inboundRate(a: std.mem.Allocator, w: []const u8, ns: []const u8) ![]u8 {
    return rate(a, .inbound, w, ns);
}
pub fn outboundLatency(a: std.mem.Allocator, w: []const u8, ns: []const u8, q: f64) ![]u8 {
    return latency(a, .outbound, w, ns, q);
}
