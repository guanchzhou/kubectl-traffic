const std = @import("std");
const line = @import("render_line");
const model = @import("model");
const table = @import("render_table");
const graph = @import("render_graph");
const app = @import("app");

const osc52 = "evil\x1b]52;c;ZWNobyBwd25lZA==\x07tail";

fn expectNoControls(s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        try std.testing.expect(s[i] >= 0x20 and s[i] != 0x7f);
        if (s[i] == 0xc2 and i + 1 < s.len) try std.testing.expect(s[i + 1] > 0x9f);
    }
}

test "sanitize replaces OSC 52 escape bytes" {
    var buf: [64]u8 = undefined;
    const out = line.sanitizeInto(&buf, osc52);
    try std.testing.expectEqualStrings("evil?]52;c;ZWNobyBwd25lZA==?tail", out);
}

test "sanitize replaces C1 controls, DEL and invalid UTF-8" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a?31mb", line.sanitizeInto(&buf, "a\xc2\x9b31mb"));
    try std.testing.expectEqualStrings("x?y", line.sanitizeInto(&buf, "x\x7fy"));
    try std.testing.expectEqualStrings("?z", line.sanitizeInto(&buf, "\xffz"));
    try std.testing.expectEqualStrings("??", line.sanitizeInto(&buf, "\xe2\x94"));
}

test "sanitize keeps printable UTF-8 and box drawing" {
    var buf: [64]u8 = undefined;
    const s = "caf\u{e9} \u{2500}\u{25B6} \u{a0}ok";
    try std.testing.expectEqualStrings(s, line.sanitizeInto(&buf, s));
}

test "sanitize caps length on a code point boundary" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("ab", line.sanitizeInto(&buf, "ab\u{2500}"));
    const long: [5000]u8 = @splat('x');
    const owned = try line.sanitizeAlloc(std.testing.allocator, &long, line.max_span_len);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqual(line.max_span_len, owned.len);
}

test "table and graph spans never carry raw escape bytes from labels" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, osc52, "ns\x1b[2J", 1.0);
    try m.setRate(.outbound, "out\xc2\x9b", "demo", 2.0);
    m.commitTick();

    const t = try table.render(std.testing.allocator, &m);
    defer table.freeLines(std.testing.allocator, t);
    for (t) |ln| for (ln.spans) |s| try expectNoControls(s.text);

    const g = try graph.render(std.testing.allocator, &m, "web\x1b]0;x\x07", "demo\x1b[31m", 6);
    defer graph.freeLines(std.testing.allocator, g);
    for (g) |ln| for (ln.spans) |s| try expectNoControls(s.text);
}

test "long title does not overflow" {
    const name: [600]u8 = @splat('a');
    const ns: [253]u8 = @splat('n');
    const title = try app.formatTitle(std.testing.allocator, "deployment", &name, &ns);
    defer std.testing.allocator.free(title);
    try std.testing.expect(std.mem.indexOf(u8, title, &name) != null);
    try std.testing.expect(std.mem.endsWith(u8, title, &ns));
}

test "graph renders a namespace longer than the old footer buffer" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    const ns: [253]u8 = @splat('n');
    const g = try graph.render(std.testing.allocator, &m, "web", &ns, 6);
    defer graph.freeLines(std.testing.allocator, g);
}
