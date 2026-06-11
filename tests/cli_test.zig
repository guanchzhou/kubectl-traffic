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

// --- parseDuration direct tests ---

test "parseDuration: 500ms" {
    try std.testing.expectEqual(@as(u64, 500), try cli.parseDuration("500ms"));
}

test "parseDuration: 2s" {
    try std.testing.expectEqual(@as(u64, 2_000), try cli.parseDuration("2s"));
}

test "parseDuration: 1m" {
    try std.testing.expectEqual(@as(u64, 60_000), try cli.parseDuration("1m"));
}

test "parseDuration: bare 's' is invalid" {
    try std.testing.expectError(error.InvalidDuration, cli.parseDuration("s"));
}

test "parseDuration: unknown suffix is invalid" {
    try std.testing.expectError(error.InvalidDuration, cli.parseDuration("5x"));
}

// --- deploy alias / long-form ---

test "deployment/ long form parses to .deployment" {
    const args = [_][]const u8{"deployment/foo"};
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(cli.Kind.deployment, c.kind);
    try std.testing.expectEqualStrings("foo", c.name);
}

// --- error cases ---

test "MissingValue: --namespace without value" {
    const args = [_][]const u8{ "pod/x", "--namespace" };
    try std.testing.expectError(error.MissingValue, cli.parse(std.testing.allocator, &args));
}

test "UnknownFlag: unrecognised flag" {
    const args = [_][]const u8{ "pod/x", "--bogus" };
    try std.testing.expectError(error.UnknownFlag, cli.parse(std.testing.allocator, &args));
}

test "InvalidTarget: trailing slash" {
    const args = [_][]const u8{"pod/"};
    try std.testing.expectError(error.InvalidTarget, cli.parse(std.testing.allocator, &args));
}

test "InvalidTop: --top 0" {
    const args = [_][]const u8{ "pod/x", "--top", "0" };
    try std.testing.expectError(error.InvalidTop, cli.parse(std.testing.allocator, &args));
}

test "HelpRequested: -h" {
    const args = [_][]const u8{"-h"};
    try std.testing.expectError(error.HelpRequested, cli.parse(std.testing.allocator, &args));
}

test "HelpRequested: --help anywhere in args" {
    const args = [_][]const u8{ "pod/x", "--help" };
    try std.testing.expectError(error.HelpRequested, cli.parse(std.testing.allocator, &args));
}
