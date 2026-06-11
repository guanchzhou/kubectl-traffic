const std = @import("std");

pub const Sample = struct {
    labels: std.StringHashMap([]const u8),
    value: f64,
};

pub const Vector = struct {
    arena: std.heap.ArenaAllocator,
    samples: []Sample,

    pub fn deinit(self: *Vector) void {
        self.arena.deinit();
    }
};

/// Parse a Prometheus `/api/v1/query` instant-vector JSON body.
/// All returned memory (labels, strings, samples) lives in the Vector's arena;
/// call .deinit() to free everything at once.
pub fn parseVector(gpa: std.mem.Allocator, body: []const u8) !Vector {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const data = parsed.object.get("data") orelse return error.BadResponse;
    const result = data.object.get("result") orelse return error.BadResponse;

    var list = std.ArrayList(Sample).empty;
    for (result.array.items) |item| {
        const metric = item.object.get("metric").?.object;
        var labels = std.StringHashMap([]const u8).init(a);
        var it = metric.iterator();
        while (it.next()) |entry| {
            try labels.put(entry.key_ptr.*, entry.value_ptr.*.string);
        }
        const value_arr = item.object.get("value").?.array;
        const vstr = value_arr.items[1].string; // [ ts, "value" ]
        const value = std.fmt.parseFloat(f64, vstr) catch std.math.nan(f64);
        try list.append(a, .{ .labels = labels, .value = value });
    }
    return .{ .arena = arena, .samples = try list.toOwnedSlice(a) };
}
