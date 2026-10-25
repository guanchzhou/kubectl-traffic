const std = @import("std");
const names = @import("names");
const cli = @import("cli");
const pc = @import("prom_client");
const discovery = @import("discovery");

const a253: [253]u8 = @splat('a');
const a254: [254]u8 = @splat('a');

test "DNS-1123 accepts typical names" {
    try std.testing.expect(names.isDns1123("default"));
    try std.testing.expect(names.isDns1123("my-api-6d7b9f-xkqp2"));
    try std.testing.expect(names.isDns1123("prometheus.v2"));
    try std.testing.expect(names.isDns1123("a"));
    try std.testing.expect(names.isDns1123(&a253));
}

test "DNS-1123 rejects unsafe or malformed names" {
    try std.testing.expect(!names.isDns1123(""));
    try std.testing.expect(!names.isDns1123(&a254));
    try std.testing.expect(!names.isDns1123("Upper"));
    try std.testing.expect(!names.isDns1123("-lead"));
    try std.testing.expect(!names.isDns1123("trail-"));
    try std.testing.expect(!names.isDns1123("a/b"));
    try std.testing.expect(!names.isDns1123(".."));
    try std.testing.expect(!names.isDns1123("x?y=1"));
    try std.testing.expect(!names.isDns1123("x%2f"));
    try std.testing.expect(!names.isDns1123("under_score"));
}

test "cli rejects invalid workload and namespace names" {
    const bad_name = [_][]const u8{"deploy/../secrets"};
    try std.testing.expectError(error.InvalidName, cli.parse(std.testing.allocator, &bad_name));
    const bad_ns = [_][]const u8{ "deploy/web", "-n", "kube-system/../x" };
    try std.testing.expectError(error.InvalidName, cli.parse(std.testing.allocator, &bad_ns));
}

test "proxy path rejects invalid namespace or service" {
    try std.testing.expectError(error.InvalidName, pc.proxyQueryPath(std.testing.allocator, "../x", "prom", 9090, "up"));
    try std.testing.expectError(error.InvalidName, pc.proxyQueryPath(std.testing.allocator, "monitoring", "prom/../../x", 9090, "up"));
}

test "prometheus override rejects invalid names" {
    try std.testing.expectError(error.BadPrometheusRef, discovery.parseOverride("prom.Mon:9090"));
    try std.testing.expectError(error.BadPrometheusRef, discovery.parseOverride("prom.:9090"));
}
