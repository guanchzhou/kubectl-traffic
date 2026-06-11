const std = @import("std");
const pc = @import("prom_client");

test "service-proxy query path is well-formed and url-encodes the query" {
    const path = try pc.proxyQueryPath(std.testing.allocator, "monitoring", "kube-prometheus-stack-prometheus", 9090, "sum by (x) (rate(y[1m]))");
    defer std.testing.allocator.free(path);
    try std.testing.expectStringStartsWith(path, "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=");
    try std.testing.expect(std.mem.indexOf(u8, path, "%20") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, " ") == null);
}
