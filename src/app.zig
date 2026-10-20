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

/// One refresh: rate + errorRate + p50/p99 per direction, folded into the model.
pub fn collectTick(client: *klient.K8sClient, a: std.mem.Allocator, m: *model.TrafficModel, tgt: discovery.PromTarget, workload: []const u8, ns: []const u8) !void {
    m.beginTick();
    const dirs = [_]model.Direction{ .inbound, .outbound };
    for (dirs) |dir| {
        const pd = promDir(dir);
        {
            const q = try promql.rate(a, pd, workload, ns);
            defer a.free(q);
            var v = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q);
            defer v.deinit();
            try applyRate(m, dir, &v, model.TrafficModel.setRate);
        }
        {
            const q = try promql.errorRate(a, pd, workload, ns);
            defer a.free(q);
            var v = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q);
            defer v.deinit();
            try applyRate(m, dir, &v, model.TrafficModel.setErrorRate);
        }
        try collectLatency(client, a, m, tgt, dir, workload, ns);
    }
    m.commitTick();
}

/// Live poll loop: collect → render → paint → wait for keypress or interval.
/// Exits cleanly on 'q' or Ctrl-C.
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

    while (true) {
        collectTick(client, allocator, &m, tgt, workload, ns) catch |err| {
            std.log.warn("collect failed: {s}", .{@errorName(err)});
        };
        const g = try render_graph.render(allocator, &m, workload, ns, top);
        defer render_graph.freeLines(allocator, g);
        const t = try render_table.render(allocator, &m);
        defer render_table.freeLines(allocator, t);
        try tui.paint(g, t, title);
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

fn collectLatency(client: *klient.K8sClient, a: std.mem.Allocator, m: *model.TrafficModel, tgt: discovery.PromTarget, dir: model.Direction, workload: []const u8, ns: []const u8) !void {
    const pd = promDir(dir);
    const name_label = if (dir == .inbound) "source_workload" else "destination_workload";
    const ns_label = if (dir == .inbound) "source_workload_namespace" else "destination_workload_namespace";

    const q50 = try promql.latency(a, pd, workload, ns, 0.5);
    defer a.free(q50);
    var v50 = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q50);
    defer v50.deinit();

    const q99 = try promql.latency(a, pd, workload, ns, 0.99);
    defer a.free(q99);
    var v99 = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q99);
    defer v99.deinit();

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
