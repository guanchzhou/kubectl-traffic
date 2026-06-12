const std = @import("std");
const model = @import("model");
const graph = @import("render_graph");

test "graph shows target, top inbound peer with rate, and totals" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "istio-ingressgw", "istio-system", 12.4);
    try m.setRate(.outbound, "baz", "demo", 5.0);

    const lines = try graph.render(std.testing.allocator, &m, "foo", "demo", 6);
    defer graph.freeLines(std.testing.allocator, lines);

    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(std.testing.allocator);
    for (lines) |ln| {
        const t = try ln.plainText(std.testing.allocator);
        defer std.testing.allocator.free(t);
        try joined.appendSlice(std.testing.allocator, t);
        try joined.append(std.testing.allocator, '\n');
    }
    const all = joined.items;
    try std.testing.expect(std.mem.indexOf(u8, all, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "istio-ingressgw") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "12.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "baz") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "in") != null);
}
