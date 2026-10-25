const std = @import("std");
const model = @import("model");

test "upsert peer rate + error -> success percent" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "demo", 10.0);
    try m.setErrorRate(.inbound, "bar", "demo", 0.2);
    const p = m.peer(.inbound, "bar").?;
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), p.req_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 98.0), p.successPercent(), 1e-9); // (1 - 0.2/10)*100
}

test "rolling history keeps last N and powers sparkline source" {
    var m = model.TrafficModel.init(std.testing.allocator, 3);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "demo", 1);
    m.commitTick();
    try m.setRate(.inbound, "bar", "demo", 2);
    m.commitTick();
    try m.setRate(.inbound, "bar", "demo", 3);
    m.commitTick();
    try m.setRate(.inbound, "bar", "demo", 4);
    m.commitTick();
    const p = m.peer(.inbound, "bar").?;
    const h = p.history();
    try std.testing.expectEqual(@as(usize, 3), h.len);
    try std.testing.expectApproxEqAbs(@as(f64, 4), h[h.len - 1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), h[0], 1e-9); // 1 evicted
}

test "totals and topN by rate" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "a", "ns", 5);
    try m.setRate(.inbound, "b", "ns", 1);
    try std.testing.expectApproxEqAbs(@as(f64, 6), m.totalRate(.inbound), 1e-9);
    const top = try m.topN(std.testing.allocator, .inbound, 1);
    defer std.testing.allocator.free(top);
    try std.testing.expectEqualStrings("a", top[0].name);
}

test "same workload name in different namespaces does not collide" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "api", "team-a", 12.0);
    try m.setRate(.inbound, "api", "team-b", 3.5);
    try std.testing.expectEqual(@as(usize, 2), m.peers.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), m.peerInNamespace(.inbound, "api", "team-a").?.req_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), m.peerInNamespace(.inbound, "api", "team-b").?.req_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 15.5), m.totalRate(.inbound), 1e-9);
}

test "beginTick zeroes stale rates for peers missing from next scrape" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "demo", 9.0);
    try m.setErrorRate(.inbound, "bar", "demo", 1.0);
    try m.setLatency(.inbound, "bar", "demo", 2.0, 15.0);
    m.commitTick();

    m.beginTick();
    const p = m.peer(.inbound, "bar").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p.req_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p.err_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p.p50_ms, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p.p99_ms, 1e-9);
}

test "addRates accumulates request and error rates" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.addRates(.inbound, "bar", "demo", 8.0, 0);
    try m.addRates(.inbound, "bar", "demo", 2.0, 2.0);
    const p = m.peer(.inbound, "bar").?;
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), p.req_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), p.successPercent(), 1e-9);
}

test "peers idle for prune_after ticks are dropped" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    m.prune_after = 3;
    try m.setRate(.inbound, "gone", "demo", 1.0);
    try m.setRate(.inbound, "busy", "demo", 1.0);
    m.commitTick();
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        m.beginTick();
        try m.setRate(.inbound, "busy", "demo", 1.0);
        m.commitTick();
    }
    try std.testing.expect(m.peer(.inbound, "gone") == null);
    try std.testing.expect(m.peer(.inbound, "busy") != null);
    try std.testing.expectEqual(@as(usize, 1), m.peers.items.len);
}
