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
