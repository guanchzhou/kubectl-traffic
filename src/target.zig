const std = @import("std");
const cli = @import("cli");
const klient = @import("klient");

pub fn workloadFromKind(kind: cli.Kind, name: []const u8) ![]const u8 {
    return switch (kind) {
        .deployment => name,
        .pod => error.NeedsOwnerResolution, // resolved live via resolvePod
    };
}

/// A ReplicaSet created by a Deployment is named "<deployment>-<podtemplatehash>".
/// Strip the final "-<hash>" segment.
pub fn deploymentFromReplicaSet(rs_name: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, rs_name, '-') orelse return rs_name;
    return rs_name[0..dash];
}

// --- Live resolution ---

/// Minimal ownerReference shape we parse from the K8s API.
/// ObjectMeta in zig-klient does not include ownerReferences, so we
/// deserialize the pod JSON ourselves using these local structs.
const OwnerRef = struct {
    kind: []const u8,
    name: []const u8,
    apiVersion: ?[]const u8 = null,
    uid: ?[]const u8 = null,
    controller: ?bool = null,
    blockOwnerDeletion: ?bool = null,
};

const PodMeta = struct {
    name: []const u8,
    namespace: ?[]const u8 = null,
    ownerReferences: ?[]OwnerRef = null,
};

const PodEnvelope = struct {
    metadata: PodMeta,
};

/// Resolve a pod name to its Istio workload name (the Deployment name).
///
/// Strategy:
///   1. Fetch the pod via GET /api/v1/namespaces/{ns}/pods/{name}.
///   2. Walk ownerReferences looking for a controller reference.
///   3. If kind == "ReplicaSet": strip the trailing pod-template-hash segment
///      from the RS name to derive the Deployment name (no extra API call needed).
///   4. If kind == "Deployment" | "StatefulSet" | "DaemonSet": use the owner name directly.
///   5. If no owners found: fall back to the pod name itself.
///
/// Ownership contract: always returns an allocator.dupe'd slice — the caller
/// owns it and must free it. This avoids lifetime coupling to the JSON parse
/// result (which is deinit'd before return).
pub fn resolvePod(
    client: *klient.K8sClient,
    allocator: std.mem.Allocator,
    ns: []const u8,
    pod_name: []const u8,
) ![]const u8 {
    // Build the pod resource path.
    const path = try std.fmt.allocPrint(
        allocator,
        "/api/v1/namespaces/{s}/pods/{s}",
        .{ ns, pod_name },
    );
    defer allocator.free(path);

    // Fetch raw JSON from the K8s API (client.request returns owned []u8).
    const body = try client.request(.GET, path, null);
    defer allocator.free(body);

    // Parse only the fields we need; ignore the rest.
    const parsed = try std.json.parseFromSlice(PodEnvelope, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const owners = parsed.value.metadata.ownerReferences orelse {
        // No ownerReferences — use pod name as the workload identity.
        return allocator.dupe(u8, pod_name);
    };

    for (owners) |ref| {
        // Prefer controller references (controller == true) when present.
        if (ref.controller != null and !ref.controller.?) continue;

        if (std.mem.eql(u8, ref.kind, "ReplicaSet")) {
            // RS name pattern: "<deployment>-<podtemplatehash>"
            const deploy_name = deploymentFromReplicaSet(ref.name);
            return allocator.dupe(u8, deploy_name);
        }
        if (std.mem.eql(u8, ref.kind, "Deployment") or
            std.mem.eql(u8, ref.kind, "StatefulSet") or
            std.mem.eql(u8, ref.kind, "DaemonSet"))
        {
            return allocator.dupe(u8, ref.name);
        }
    }

    // No recognised workload owner — fall back to the pod name.
    return allocator.dupe(u8, pod_name);
}
