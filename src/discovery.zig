const std = @import("std");
const klient = @import("klient");

pub const PromTarget = struct { namespace: []const u8, service: []const u8, port: u16 };

/// Default well-known Prometheus on AlphaSense clusters.
pub fn default() PromTarget {
    return .{ .namespace = "monitoring", .service = "kube-prometheus-stack-prometheus", .port = 9090 };
}

/// Parse "svc.ns:port" override form.
pub fn parseOverride(ref: []const u8) !PromTarget {
    const colon = std.mem.lastIndexOfScalar(u8, ref, ':') orelse return error.BadPrometheusRef;
    const svc_ns = ref[0..colon];
    const port = try std.fmt.parseInt(u16, ref[colon + 1 ..], 10);
    const dot = std.mem.indexOfScalar(u8, svc_ns, '.') orelse return error.BadPrometheusRef;
    return .{ .service = svc_ns[0..dot], .namespace = svc_ns[dot + 1 ..], .port = port };
}
