const std = @import("std");

/// Escape a PromQL label value (backslash, double-quote, newline, carriage
/// return). Caller owns result.
pub fn escape(allocator: std.mem.Allocator, v: []const u8) ![]u8 {
    var extra: usize = 0;
    for (v) |c| {
        if (escapeChar(c) != null) extra += 1;
    }
    if (extra == 0) return allocator.dupe(u8, v);
    var buf = try allocator.alloc(u8, v.len + extra);
    var i: usize = 0;
    for (v) |c| {
        if (escapeChar(c)) |e| {
            buf[i] = '\\';
            buf[i + 1] = e;
            i += 2;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf;
}

fn escapeChar(c: u8) ?u8 {
    return switch (c) {
        '\\', '"' => c,
        '\n' => 'n',
        '\r' => 'r',
        else => null,
    };
}

pub const Direction = enum { inbound, outbound };

fn selfRole(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "destination", // we are the destination; peers are the sources
        .outbound => "source",
    };
}
fn reporterClause(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "reporter=~\"destination|waypoint\"",
        .outbound => "reporter=\"source\"",
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
        "{s},{s}_workload=\"{s}\",{s}_workload_namespace=\"{s}\"",
        .{ reporterClause(dir), role, ew, role, en },
    );
}

pub fn rate(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}) (rate(istio_requests_total{{{s}}}[5m]))",
        .{ peerLabel(dir), sel },
    );
}

pub fn errorRate(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}) (rate(istio_requests_total{{{s},response_code=~\"5..\"}}[5m]))",
        .{ peerLabel(dir), sel },
    );
}

/// Label added by `rateWithErrors`: "5" on 5xx series, absent otherwise.
pub const error_class_label = "kt_class";

/// Request rate and 5xx rate in one query: at most two series per peer, the
/// 5xx one tagged with `error_class_label`="5". Total = sum of both series.
pub fn rateWithErrors(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}, {s}) (label_replace(rate(istio_requests_total{{{s}}}[5m]), \"{s}\", \"$1\", \"response_code\", \"(5)..\"))",
        .{ peerLabel(dir), error_class_label, sel, error_class_label },
    );
}

pub fn latency(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8, quantile: f64) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "histogram_quantile({d}, sum by (le, {s}) (rate(istio_request_duration_milliseconds_bucket{{{s}}}[5m])))",
        .{ quantile, peerLabel(dir), sel },
    );
}

pub fn inboundRate(a: std.mem.Allocator, w: []const u8, ns: []const u8) ![]u8 {
    return rate(a, .inbound, w, ns);
}
pub fn outboundLatency(a: std.mem.Allocator, w: []const u8, ns: []const u8, q: f64) ![]u8 {
    return latency(a, .outbound, w, ns, q);
}
