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
///
/// Safety note: `.allocate = .alloc_always` is passed so every JSON string is
/// copied into the arena rather than aliasing the input `body` slice. This
/// means the caller can free `body` immediately after this call without
/// creating use-after-free in the returned Vector.
pub fn parseVector(gpa: std.mem.Allocator, body: []const u8) !Vector {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always });
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

fn percentEncode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    for (s) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(a, ch);
        } else {
            var tmp: [3]u8 = undefined;
            const hex = try std.fmt.bufPrint(&tmp, "%{X:0>2}", .{@as(u8, ch)});
            try out.appendSlice(a, hex);
        }
    }
    return out.toOwnedSlice(a);
}

pub fn proxyQueryPath(a: std.mem.Allocator, ns: []const u8, svc: []const u8, port: u16, promql: []const u8) ![]u8 {
    const enc = try percentEncode(a, promql);
    defer a.free(enc);
    return std.fmt.allocPrint(
        a,
        "/api/v1/namespaces/{s}/services/{s}:{d}/proxy/api/v1/query?query={s}",
        .{ ns, svc, port, enc },
    );
}

/// Live: run a PromQL query through the API-server service proxy.
/// Returns the parsed instant vector; caller calls .deinit().
///
/// Allocator convention (matches target.zig resolvePod): `a` is expected to
/// be the same allocator used to initialise the K8sClient so that
/// `defer a.free(body)` correctly frees the body returned by client.request.
/// parseVector uses `.alloc_always` so all strings are copied into its own
/// arena before body is freed — no use-after-free.
pub fn query(client: *@import("klient").K8sClient, a: std.mem.Allocator, ns: []const u8, svc: []const u8, port: u16, promql: []const u8) !Vector {
    const path = try proxyQueryPath(a, ns, svc, port, promql);
    defer a.free(path);
    const body = try client.request(.GET, path, null);
    defer a.free(body);
    return parseVector(a, body);
}
