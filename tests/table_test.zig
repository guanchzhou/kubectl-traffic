const std = @import("std");
const model = @import("model");
const table = @import("render_table");

test "table renders a header + a peer row per direction" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "demo", 3.1);
    try m.setLatency(.inbound, "bar", "demo", 4, 11);
    m.commitTick();

    const lines = try table.render(std.testing.allocator, &m);
    defer table.freeLines(std.testing.allocator, lines);

    var found = false;
    for (lines) |ln| {
        const txt = try ln.plainText(std.testing.allocator);
        defer std.testing.allocator.free(txt);
        if (std.mem.indexOf(u8, txt, "bar") != null and std.mem.indexOf(u8, txt, "3.1") != null) found = true;
    }
    try std.testing.expect(found);
}
