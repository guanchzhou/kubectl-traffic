const std = @import("std");
const klient = @import("klient");
const bootstrap = @import("bootstrap");
const app = @import("app");
const model = @import("model");
const discovery = @import("discovery");

test "live: bootstrap + one collectTick against a meshed workload (gated by KT_LIVE)" {
    const gpa = std.testing.allocator;

    // Gate: skip unless KT_LIVE is set.
    const kt_live = std.c.getenv("KT_LIVE");
    if (kt_live == null) return error.SkipZigTest;

    // Read target from env; require KT_LIVE_WORKLOAD.
    const workload_ptr = std.c.getenv("KT_LIVE_WORKLOAD") orelse return error.SkipZigTest;
    const workload: []const u8 = std.mem.span(workload_ptr);

    const ns_ptr = std.c.getenv("KT_LIVE_NS");
    const ns: []const u8 = if (ns_ptr) |p| std.mem.span(p) else "ef-test";

    const ctx_ptr = std.c.getenv("KT_LIVE_CONTEXT");
    const ctx_override: ?[]const u8 = if (ctx_ptr) |p| std.mem.span(p) else null;

    // Build a Threaded Io so bootstrap can run exec-credential plugins and
    // make network calls.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var boot = try bootstrap.fromKubeconfig(gpa, io, ctx_override);
    defer boot.deinit();

    var m = model.TrafficModel.init(gpa, 8);
    defer m.deinit();

    const tgt = discovery.default();
    try app.collectTick(&boot.client, gpa, &m, tgt, workload, ns);

    // Print what we found so a human running KT_LIVE can eyeball it.
    std.debug.print("\n[live] inbound peers: {d}, outbound peers: {d}\n", .{
        countDir(&m, .inbound),
        countDir(&m, .outbound),
    });
}

fn countDir(m: *model.TrafficModel, dir: model.Direction) usize {
    var n: usize = 0;
    for (m.peers.items) |p| if (p.dir == dir) {
        n += 1;
    };
    return n;
}
