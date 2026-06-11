const std = @import("std");
const discovery = @import("discovery");

test "default prometheus target" {
    const t = discovery.default();
    try std.testing.expectEqualStrings("monitoring", t.namespace);
    try std.testing.expectEqual(@as(u16, 9090), t.port);
}

test "parseOverride svc.ns:port" {
    const t = try discovery.parseOverride("prometheus-operated.monitoring:9090");
    try std.testing.expectEqualStrings("prometheus-operated", t.service);
    try std.testing.expectEqualStrings("monitoring", t.namespace);
    try std.testing.expectEqual(@as(u16, 9090), t.port);
    try std.testing.expectError(error.BadPrometheusRef, discovery.parseOverride("noport"));
}
