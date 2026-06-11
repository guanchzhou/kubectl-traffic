const std = @import("std");

/// Escape backslash and double-quote in a PromQL label value.
/// Caller owns the returned slice.
pub fn escape(allocator: std.mem.Allocator, v: []const u8) ![]u8 {
    // Count extra bytes needed (each \ or " needs one extra char for the backslash)
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

const Role = enum { inbound, outbound };

/// Build a PromQL label selector fragment for the workload side.
/// For inbound: destination_workload + destination_workload_namespace
/// For outbound: source_workload + source_workload_namespace
fn workloadSelector(allocator: std.mem.Allocator, role: Role, workload: []const u8, ns: []const u8) ![]u8 {
    const escaped = try escape(allocator, workload);
    defer allocator.free(escaped);
    return switch (role) {
        .inbound => std.fmt.allocPrint(
            allocator,
            "destination_workload=\"{s}\",destination_workload_namespace=\"{s}\"",
            .{ escaped, ns },
        ),
        .outbound => std.fmt.allocPrint(
            allocator,
            "source_workload=\"{s}\",source_workload_namespace=\"{s}\"",
            .{ escaped, ns },
        ),
    };
}

/// reporter label: "destination" for inbound, "source" for outbound.
fn reporterLabel(role: Role) []const u8 {
    return switch (role) {
        .inbound => "destination",
        .outbound => "source",
    };
}

/// Build the inbound request-rate query:
///   sum by (source_workload, source_workload_namespace)
///     (rate(istio_requests_total{reporter="destination",...}[1m]))
/// Caller owns the returned slice.
pub fn inboundRate(allocator: std.mem.Allocator, workload: []const u8, ns: []const u8) ![]u8 {
    const wsel = try workloadSelector(allocator, .inbound, workload, ns);
    defer allocator.free(wsel);

    return std.fmt.allocPrint(
        allocator,
        "sum by (source_workload, source_workload_namespace) " ++
            "(rate(istio_requests_total{{reporter=\"{s}\",{s}}}[1m]))",
        .{ reporterLabel(.inbound), wsel },
    );
}

/// Build the outbound latency histogram_quantile query:
///   histogram_quantile(<q>, sum by (le, destination_workload, destination_workload_namespace)
///     (rate(istio_request_duration_milliseconds_bucket{reporter="source",...}[1m])))
/// Caller owns the returned slice.
pub fn outboundLatency(allocator: std.mem.Allocator, workload: []const u8, ns: []const u8, quantile: f64) ![]u8 {
    const wsel = try workloadSelector(allocator, .outbound, workload, ns);
    defer allocator.free(wsel);

    return std.fmt.allocPrint(
        allocator,
        "histogram_quantile({d}, sum by (le, destination_workload, destination_workload_namespace) " ++
            "(rate(istio_request_duration_milliseconds_bucket{{reporter=\"{s}\",{s}}}[1m])))",
        .{ quantile, reporterLabel(.outbound), wsel },
    );
}
