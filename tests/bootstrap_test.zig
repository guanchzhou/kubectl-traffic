const std = @import("std");
const bootstrap = @import("bootstrap");

test "eks cluster name parsed from exec args" {
    const args = [_][]const u8{ "eks", "get-token", "--cluster-name", "test-cluster", "--region", "us-east-1" };
    try std.testing.expectEqualStrings("test-cluster", bootstrap.eksClusterNameFromArgs(&args).?);
}

test "eks cluster name absent returns null" {
    const args = [_][]const u8{ "eks", "get-token" };
    try std.testing.expect(bootstrap.eksClusterNameFromArgs(&args) == null);
}
