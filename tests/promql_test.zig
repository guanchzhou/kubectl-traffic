const std = @import("std");
const promql = @import("promql");

test "inbound rate query shape + escaping" {
    const q = try promql.inboundRate(std.testing.allocator, "foo\"x", "demo");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=~\"destination|waypoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload=\"foo\\\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload_namespace=\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "sum by (source_workload, source_workload_namespace)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "rate(istio_requests_total{") != null);
}

test "outbound latency p99 query shape" {
    const q = try promql.outboundLatency(std.testing.allocator, "foo", "demo", 0.99);
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "histogram_quantile(0.99") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "source_workload=\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "istio_request_duration_milliseconds_bucket{") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "by (le, destination_workload") != null);
}

test "errorRate restricts to 5xx" {
    const q = try promql.errorRate(std.testing.allocator, .inbound, "foo", "demo");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "response_code=~\"5..\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=~\"destination|waypoint\"") != null);
}

test "inbound matches both sidecar and ambient reporters" {
    const q = try promql.rate(std.testing.allocator, .inbound, "foo", "demo");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=~\"destination|waypoint\"") != null);
    // must NOT use an exact reporter="destination" match
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"destination\"") == null);
}

test "outbound rate groups by destination workload" {
    const q = try promql.rate(std.testing.allocator, .outbound, "foo", "demo");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "source_workload=\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "sum by (destination_workload, destination_workload_namespace)") != null);
}

test "namespace is escaped too" {
    const q = try promql.rate(std.testing.allocator, .inbound, "foo", "ns\"x");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload_namespace=\"ns\\\"x\"") != null);
}
