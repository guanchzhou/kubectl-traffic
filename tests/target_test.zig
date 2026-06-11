const std = @import("std");
const target = @import("target");

test "deployment target maps straight to workload" {
    const w = try target.workloadFromKind(.deployment, "foo");
    try std.testing.expectEqualStrings("foo", w);
}

test "workload name derived from replicaset owner name" {
    try std.testing.expectEqualStrings("foo", target.deploymentFromReplicaSet("foo-7d9c"));
    try std.testing.expectEqualStrings("my-app", target.deploymentFromReplicaSet("my-app-abc123"));
}
