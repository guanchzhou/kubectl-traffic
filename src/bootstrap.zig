const std = @import("std");
const klient = @import("klient");

/// Parse an EKS cluster name from an exec-credential args slice.
/// Looks for `--cluster-name <value>` and returns the value, or null if absent.
pub fn eksClusterNameFromArgs(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cluster-name")) return args[i + 1];
    }
    return null;
}

pub const Bootstrapped = struct {
    client: klient.K8sClient,
    namespace: []const u8,
};

/// Build an authenticated K8sClient from the current kubeconfig context.
///
/// `context_override` selects a named context; null uses current-context.
///
/// Callers own the returned `Bootstrapped` and must call `client.deinit()` when
/// done.  The `namespace` slice is owned by the K8sClient allocator — do not
/// free it separately.
pub fn fromKubeconfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    context_override: ?[]const u8,
) !Bootstrapped {
    // ---- 1. Parse kubeconfig ----
    var parser = klient.KubeconfigParser.init(allocator, io);
    var kc = try parser.load();
    defer kc.deinit(allocator);

    // ---- 2. Resolve context ----
    const context = (if (context_override) |n|
        kc.getContextByName(n)
    else
        kc.getCurrentContext()) orelse return error.NoContext;

    // ---- 3. Resolve cluster + user ----
    const cluster = kc.getClusterByName(context.cluster) orelse return error.NoCluster;
    const user = kc.getUserByName(context.user) orelse return error.NoUser;

    // ---- 4. Resolve bearer token ----
    // exec-credential plugins (e.g. `aws eks get-token`) take priority over a
    // static token.
    var token: ?[]const u8 = null;
    var exec_cred: ?std.json.Parsed(klient.ExecCredential) = null;
    defer if (exec_cred) |*ec| ec.deinit();

    if (user.exec) |kc_exec| {
        // kubeconfig_yaml.ExecConfig.command is ?[]const u8; the exec_credential
        // plugin expects a non-optional command string.
        const cmd = kc_exec.command orelse return error.ExecConfigMissingCommand;

        // Bridge from kubeconfig_yaml.ExecConfig -> exec_credential.ExecConfig.
        // Field name difference: kubeconfig uses `api_version`, exec_credential
        // uses `apiVersion`.
        const plugin_cfg = klient.exec_credential.ExecConfig{
            .command = cmd,
            .args = kc_exec.args,
            .apiVersion = kc_exec.api_version orelse "client.authentication.k8s.io/v1",
        };

        exec_cred = try klient.exec_credential.executeCredentialPlugin(
            allocator,
            io,
            plugin_cfg,
        );

        if (exec_cred.?.value.status) |status| {
            token = status.token;
        }
    } else if (user.token) |t| {
        token = t;
    }

    // ---- 5. Build TLS config ----
    // Cluster.certificate_authority_data = base64 PEM from kubeconfig.
    // Cluster.certificate_authority      = path to CA bundle file.
    // TlsConfig.ca_cert_data / .ca_cert_path are the matching fields.
    const tls_cfg: ?klient.TlsConfig = if (cluster.certificate_authority_data) |ca|
        .{ .ca_cert_data = ca }
    else if (cluster.certificate_authority) |ca_path|
        .{ .ca_cert_path = ca_path }
    else
        null;

    // ---- 6. Build client ----
    const ns = context.namespace orelse "default";

    const client = try klient.K8sClient.init(allocator, io, .{
        .server = cluster.server,
        .token = token,
        .namespace = ns,
        .tls_config = tls_cfg,
    });

    return Bootstrapped{
        .client = client,
        .namespace = ns,
    };
}
