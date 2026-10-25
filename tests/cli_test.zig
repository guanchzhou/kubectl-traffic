const std = @import("std");
const cli = @import("cli");

test "parse deploy target with flags" {
    const args = [_][]const u8{ "deploy/foo", "-n", "demo", "--interval", "5s", "--top", "8" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(cli.Kind.deployment, c.kind);
    try std.testing.expectEqualStrings("foo", c.name);
    try std.testing.expectEqualStrings("demo", c.namespace.?);
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

// --- --server and --once ---

test "--server and --once: both set" {
    const args = [_][]const u8{ "deploy/web", "--server", "http://127.0.0.1:8001", "--once" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqualStrings("http://127.0.0.1:8001", c.server.?);
    try std.testing.expect(c.once);
}

test "--once defaults to false" {
    const args = [_][]const u8{"deploy/web"};
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expect(!c.once);
}

test "--server defaults to null" {
    const args = [_][]const u8{"deploy/web"};
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expect(c.server == null);
}

test "--server MissingValue" {
    const args = [_][]const u8{ "deploy/web", "--server" };
    try std.testing.expectError(error.MissingValue, cli.parse(std.testing.allocator, &args));
}

test "--once alone (no --server) is valid" {
    const args = [_][]const u8{ "deploy/web", "--once" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expect(c.once);
    try std.testing.expect(c.server == null);
}

// --- --interval minimum and --context ---

test "--interval below 250ms is rejected" {
    const args = [_][]const u8{ "deploy/web", "--interval", "100ms" };
    try std.testing.expectError(error.IntervalTooShort, cli.parse(std.testing.allocator, &args));
    const zero = [_][]const u8{ "deploy/web", "--interval", "0s" };
    try std.testing.expectError(error.IntervalTooShort, cli.parse(std.testing.allocator, &zero));
}

test "--interval 250ms is accepted" {
    const args = [_][]const u8{ "deploy/web", "--interval", "250ms" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(@as(u64, 250), c.interval_ms);
}

test "--context sets the kubeconfig context" {
    const args = [_][]const u8{ "deploy/web", "--context", "prod-eu" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqualStrings("prod-eu", c.context.?);
    const none = [_][]const u8{"deploy/web"};
    try std.testing.expect((try cli.parse(std.testing.allocator, &none)).context == null);
}

test "help text does not claim Prometheus auto-discovery" {
    try std.testing.expect(std.mem.indexOf(u8, cli.Cli.help, "auto-discover") == null);
    try std.testing.expect(std.mem.indexOf(u8, cli.Cli.help, "--context") != null);
}
