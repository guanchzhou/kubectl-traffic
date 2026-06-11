const std = @import("std");
const cli = @import("cli");
const bootstrap = @import("bootstrap");
const discovery = @import("discovery");
const target = @import("target");
const app = @import("app");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // toSlice uses the arena allocator; result lifetime = process arena lifetime.
    const raw = try init.minimal.args.toSlice(init.arena.allocator());

    if (raw.len < 2) {
        std.debug.print("{s}\n", .{cli.Cli.help});
        return;
    }

    // Build a []const []const u8 from the sentinel-terminated slice so cli.parse
    // receives the type it expects.
    const args_buf = try allocator.alloc([]const u8, raw.len - 1);
    defer allocator.free(args_buf);
    for (raw[1..], 0..) |a, i| args_buf[i] = a;

    const c = cli.parse(allocator, args_buf) catch |err| {
        if (err == error.HelpRequested) {
            std.debug.print("{s}\n", .{cli.Cli.help});
            return;
        }
        std.debug.print("error: {s}\n\n{s}\n", .{ @errorName(err), cli.Cli.help });
        return err;
    };

    var boot = try bootstrap.fromKubeconfig(allocator, io, null);
    defer boot.deinit();

    const ns = c.namespace orelse boot.namespace;

    const workload = switch (c.kind) {
        .deployment => c.name,
        .pod => try target.resolvePod(&boot.client, allocator, ns, c.name),
    };

    const tgt = if (c.prometheus) |ref| try discovery.parseOverride(ref) else discovery.default();

    var title_buf: [160]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s}/{s} . ns:{s}", .{ @tagName(c.kind), c.name, ns });

    try app.run(allocator, &boot.client, tgt, workload, ns, c.interval_ms, c.top, title);
}
