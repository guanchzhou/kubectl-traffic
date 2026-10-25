const std = @import("std");
const klient = @import("klient");
const names = @import("names");

pub const PromTarget = struct { namespace: []const u8, service: []const u8, port: u16 };

/// Default Prometheus service. `prometheus-operated` is the prometheus-operator
/// governing Service, created in the operator's namespace whenever at least one
/// Prometheus replica is Ready — so it's present across clusters with a healthy
/// kube-prometheus-stack. Override per-cluster with --prometheus when it differs.
pub fn default() PromTarget {
    return .{ .namespace = "monitoring", .service = "prometheus-operated", .port = 9090 };
}

/// Parse "svc.ns:port" override form.
pub fn parseOverride(ref: []const u8) !PromTarget {
    const colon = std.mem.lastIndexOfScalar(u8, ref, ':') orelse return error.BadPrometheusRef;
    const svc_ns = ref[0..colon];
    const port = try std.fmt.parseInt(u16, ref[colon + 1 ..], 10);
    const dot = std.mem.indexOfScalar(u8, svc_ns, '.') orelse return error.BadPrometheusRef;
    const t: PromTarget = .{ .service = svc_ns[0..dot], .namespace = svc_ns[dot + 1 ..], .port = port };
    if (!names.isDns1123(t.service) or !names.isDns1123(t.namespace)) return error.BadPrometheusRef;
    return t;
}
