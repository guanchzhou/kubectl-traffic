const std = @import("std");
const cli = @import("cli");

test "parse deploy target with flags" {
    const args = [_][]const u8{ "deploy/foo", "-n", "ef-test", "--interval", "5s", "--top", "8" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(cli.Kind.deployment, c.kind);
    try std.testing.expectEqualStrings("foo", c.name);
    try std.testing.expectEqualStrings("ef-test", c.namespace.?);
    try std.testing.expectEqual(@as(u64, 5_000), c.interval_ms);
    try std.testing.expectEqual(@as(usize, 8), c.top);
}

test "defaults: pod kind, 2s interval, top 6, namespace null" {
    const args = [_][]const u8{"pod/bar-abc"};
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(cli.Kind.pod, c.kind);
    try std.testing.expectEqualStrings("bar-abc", c.name);
    try std.testing.expect(c.namespace == null);
    try std.testing.expectEqual(@as(u64, 2_000), c.interval_ms);
    try std.testing.expectEqual(@as(usize, 6), c.top);
}

test "rejects missing slash" {
    const args = [_][]const u8{"foo"};
    try std.testing.expectError(error.InvalidTarget, cli.parse(std.testing.allocator, &args));
}
