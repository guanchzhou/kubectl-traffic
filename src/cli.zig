const std = @import("std");

pub const Kind = enum { pod, deployment };

pub const Cli = struct {
    kind: Kind,
    name: []const u8, // borrows from argv; do not free
    namespace: ?[]const u8 = null,
    interval_ms: u64 = 2_000,
    top: usize = 6,
    prometheus: ?[]const u8 = null, // form "svc.<ns>:<port>"

    pub const help =
        \\Usage: kubectl traffic <pod|deploy>/<name> [flags]
        \\  -n, --namespace <ns>   target namespace (default: context ns)
        \\      --interval <dur>   refresh interval, e.g. 2s, 500ms (default 2s)
        \\      --top <n>          peers drawn in graph per direction (default 6)
        \\      --prometheus <ref> svc.<ns>:<port> override (default: auto-discover)
        \\  -h, --help
    ;
};

fn parseTarget(arg: []const u8) !struct { kind: Kind, name: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, arg, '/') orelse return error.InvalidTarget;
    const k = arg[0..slash];
    const n = arg[slash + 1 ..];
    if (n.len == 0) return error.InvalidTarget;
    const kind: Kind = if (std.mem.eql(u8, k, "pod"))
        .pod
    else if (std.mem.eql(u8, k, "deploy") or std.mem.eql(u8, k, "deployment"))
        .deployment
    else
        return error.InvalidTarget;
    return .{ .kind = kind, .name = n };
}

/// Parse "2s" / "500ms" / "1m" -> milliseconds.
pub fn parseDuration(s: []const u8) !u64 {
    if (std.mem.endsWith(u8, s, "ms")) {
        return std.fmt.parseInt(u64, s[0 .. s.len - 2], 10);
    } else if (std.mem.endsWith(u8, s, "s")) {
        return (try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10)) * 1_000;
    } else if (std.mem.endsWith(u8, s, "m")) {
        return (try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10)) * 60_000;
    }
    return error.InvalidDuration;
}

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    _ = allocator; // values borrow argv; allocator reserved for future owned fields
    if (args.len == 0) return error.InvalidTarget;
    const t = try parseTarget(args[0]);
    var c = Cli{ .kind = t.kind, .name = t.name };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--namespace")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.namespace = args[i];
        } else if (std.mem.eql(u8, a, "--interval")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.interval_ms = try parseDuration(args[i]);
        } else if (std.mem.eql(u8, a, "--top")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.top = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--prometheus")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.prometheus = args[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return c;
}
