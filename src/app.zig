const std = @import("std");
const klient = @import("klient");
const model = @import("model");
const promql = @import("promql");
const prom = @import("prom_client");
const discovery = @import("discovery");
const render_graph = @import("render_graph");
const render_table = @import("render_table");
const tui_mod = @import("render_tui");

/// Function pointer type for model setters that take (model, dir, name, ns, value).
/// anyerror!void allows concrete error sets to coerce up.
pub const Setter = *const fn (*model.TrafficModel, model.Direction, []const u8, []const u8, f64) anyerror!void;

/// Fold a parsed instant-vector into the model via `setter`, keyed by the
/// peer workload label for the given direction.
pub fn applyRate(m: *model.TrafficModel, dir: model.Direction, v: *prom.Vector, setter: Setter) !void {
    const name_label = if (dir == .inbound) "source_workload" else "destination_workload";
    const ns_label = if (dir == .inbound) "source_workload_namespace" else "destination_workload_namespace";
    for (v.samples) |s| {
        const name = s.labels.get(name_label) orelse continue;
        const ns = s.labels.get(ns_label) orelse "";
        try setter(m, dir, name, ns, s.value);
    }
}

fn promDir(dir: model.Direction) promql.Direction {
    return switch (dir) {
        .inbound => .inbound,
        .outbound => .outbound,
    };
}

/// Fold a `promql.rateWithErrors` result into the model: every series adds to
/// the peer's request rate, series tagged as 5xx also add to its error rate.
pub fn applyRateWithErrors(m: *model.TrafficModel, dir: model.Direction, v: *prom.Vector) !void {
    const name_label = if (dir == .inbound) "source_workload" else "destination_workload";
    const ns_label = if (dir == .inbound) "source_workload_namespace" else "destination_workload_namespace";
    for (v.samples) |s| {
        if (!std.math.isFinite(s.value)) continue;
        const name = s.labels.get(name_label) orelse continue;
        const pns = s.labels.get(ns_label) orelse "";
        const is_5xx = if (s.labels.get(promql.error_class_label)) |c| std.mem.eql(u8, c, "5") else false;
        try m.addRates(dir, name, pns, s.value, if (is_5xx) s.value else 0);
    }
}

const DirVectors = struct {
    rates: prom.Vector,
    p50: prom.Vector,
    p99: prom.Vector,

    fn deinit(self: *DirVectors) void {
        self.rates.deinit();
        self.p50.deinit();
        self.p99.deinit();
    }
};

fn queryVector(client: *klient.K8sClient, a: std.mem.Allocator, tgt: discovery.PromTarget, q: []const u8) !prom.Vector {
    defer a.free(q);
    return prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q);
}

fn fetchDir(client: *klient.K8sClient, a: std.mem.Allocator, tgt: discovery.PromTarget, dir: model.Direction, workload: []const u8, ns: []const u8) !DirVectors {
    const pd = promDir(dir);
    var rates = try queryVector(client, a, tgt, try promql.rateWithErrors(a, pd, workload, ns));
    errdefer rates.deinit();
    var p50 = try queryVector(client, a, tgt, try promql.latency(a, pd, workload, ns, 0.5));
    errdefer p50.deinit();
    const p99 = try queryVector(client, a, tgt, try promql.latency(a, pd, workload, ns, 0.99));
    return .{ .rates = rates, .p50 = p50, .p99 = p99 };
}

/// One refresh: rate + 5xx rate and p50/p99 per direction. All queries run
/// before the model is touched, so a failed tick leaves the previous values.
pub fn collectTick(client: *klient.K8sClient, a: std.mem.Allocator, m: *model.TrafficModel, tgt: discovery.PromTarget, workload: []const u8, ns: []const u8) !void {
    var in = try fetchDir(client, a, tgt, .inbound, workload, ns);
    defer in.deinit();
    var out = try fetchDir(client, a, tgt, .outbound, workload, ns);
    defer out.deinit();

    m.beginTick();
    try applyRateWithErrors(m, .inbound, &in.rates);
    try applyLatency(m, .inbound, &in.p50, &in.p99);
    try applyRateWithErrors(m, .outbound, &out.rates);
    try applyLatency(m, .outbound, &out.p50, &out.p99);
    m.commitTick();
}

/// "<kind>/<name> . ns:<ns>"; caller owns the result.
pub fn formatTitle(a: std.mem.Allocator, kind: []const u8, name: []const u8, ns: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s} . ns:{s}", .{ kind, name, ns });
}

/// Live poll loop: collect → render → paint → wait for keypress or interval.
/// Exits cleanly on 'q' or Ctrl-C. A failed refresh keeps the last values on
/// screen and reports the error in the status line.
pub fn run(
    allocator: std.mem.Allocator,
    client: *klient.K8sClient,
    tgt: discovery.PromTarget,
    workload: []const u8,
    ns: []const u8,
    interval_ms: u64,
    top: usize,
    title: []const u8,
) !void {
    var m = model.TrafficModel.init(allocator, 32);
    defer m.deinit();

    var tui = try tui_mod.Tui.init();
    defer tui.deinit();

    var last_err: ?anyerror = null;
    var status_buf: [128]u8 = undefined;
    while (true) {
        if (collectTick(client, allocator, &m, tgt, workload, ns)) |_| {
            last_err = null;
        } else |err| {
            last_err = err;
        }
        const g = try render_graph.render(allocator, &m, workload, ns, top);
        defer render_graph.freeLines(allocator, g);
        const t = try render_table.render(allocator, &m);
        defer render_table.freeLines(allocator, t);
        const status: ?[]const u8 = if (last_err) |e|
            std.fmt.bufPrint(&status_buf, "refresh failed: {s} (showing last values)", .{@errorName(e)}) catch "refresh failed"
        else
            null;
        try tui.paint(g, t, title, status);
        if (try tui.poll(interval_ms) == .quit) break;
    }
}

/// One-shot collect + render: gather a single tick of metrics, render graph and
/// table, print a plain frame to stdout, then return.  Does not touch
/// termios/alt-screen; safe for piped / non-tty output.  Used by --once.
pub fn runOnce(
    allocator: std.mem.Allocator,
    client: *klient.K8sClient,
    tgt: discovery.PromTarget,
    workload: []const u8,
    ns: []const u8,
    top: usize,
    title: []const u8,
) !void {
    var m = model.TrafficModel.init(allocator, 32);
    defer m.deinit();
    try collectTick(client, allocator, &m, tgt, workload, ns);
    const g = try render_graph.render(allocator, &m, workload, ns, top);
    defer render_graph.freeLines(allocator, g);
    const t = try render_table.render(allocator, &m);
    defer render_table.freeLines(allocator, t);
    try tui_mod.printFrame(g, t, title);
}

/// Join p50 and p99 vectors by peer and store both latencies.
pub fn applyLatency(m: *model.TrafficModel, dir: model.Direction, v50: *prom.Vector, v99: *prom.Vector) !void {
    const name_label = if (dir == .inbound) "source_workload" else "destination_workload";
    const ns_label = if (dir == .inbound) "source_workload_namespace" else "destination_workload_namespace";
    for (v50.samples) |s| {
        const name = s.labels.get(name_label) orelse continue;
        const pns = s.labels.get(ns_label) orelse "";
        var p99: f64 = 0;
        for (v99.samples) |s2| {
            const n2 = s2.labels.get(name_label) orelse "";
            const ns2 = s2.labels.get(ns_label) orelse "";
            if (std.mem.eql(u8, n2, name) and std.mem.eql(u8, ns2, pns)) p99 = s2.value;
        }
        try m.setLatency(dir, name, pns, s.value, p99);
    }
}
