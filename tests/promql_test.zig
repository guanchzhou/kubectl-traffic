const std = @import("std");
const promql = @import("promql");

test "inbound rate query shape + escaping" {
    const q = try promql.inboundRate(std.testing.allocator, "foo\"x", "ef-test");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"destination\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload=\"foo\\\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload_namespace=\"ef-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "sum by (source_workload, source_workload_namespace)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "rate(istio_requests_total{") != null);
}

test "outbound latency p99 query shape" {
    const q = try promql.outboundLatency(std.testing.allocator, "foo", "ef-test", 0.99);
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "histogram_quantile(0.99") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "source_workload=\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "istio_request_duration_milliseconds_bucket{") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "by (le, destination_workload") != null);
}
