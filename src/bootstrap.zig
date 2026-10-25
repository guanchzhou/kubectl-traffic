const std = @import("std");
const klient = @import("klient");

// Canonical type alias — Kubeconfig is now re-exported from klient alongside
// KubeconfigParser so callers don't need to reach into the internal module.
const Kubeconfig = klient.Kubeconfig;
pub const Cluster = @typeInfo(@FieldType(Kubeconfig, "clusters")).pointer.child;
pub const User = @typeInfo(@FieldType(Kubeconfig, "users")).pointer.child;

pub const UnsupportedError = error{ ClientCertificatesUnsupported, InsecureSkipVerifyUnsupported };

/// zig-klient cannot present a client certificate or skip TLS verification
/// (Zig std TLS exposes neither). Reject such kubeconfigs before running any
/// exec-credential plugin. A client certificate alongside a token or exec
/// plugin is ignored and the bearer token is used.
pub fn checkSupported(cluster: Cluster, user: User) UnsupportedError!void {
    const has_cert = user.client_certificate != null or user.client_certificate_data != null or
        user.client_key != null or user.client_key_data != null;
    if (has_cert and user.token == null and user.exec == null) return error.ClientCertificatesUnsupported;
    if (cluster.insecure_skip_tls_verify orelse false) return error.InsecureSkipVerifyUnsupported;
}

/// Human-readable explanation and workaround for errors from `checkSupported`.
pub fn unsupportedMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ClientCertificatesUnsupported =>
        \\the kubeconfig user authenticates with a client certificate, which
        \\kubectl-traffic cannot present (Zig's TLS client has no client-certificate support).
        \\Workaround: run `kubectl proxy` in another terminal, then pass
        \\  --server http://127.0.0.1:8001
        ,
        error.InsecureSkipVerifyUnsupported =>
        \\the kubeconfig cluster sets insecure-skip-tls-verify, which kubectl-traffic
        \\does not support. Configure certificate-authority(-data) for the cluster, or
        \\run `kubectl proxy` in another terminal and pass
        \\  --server http://127.0.0.1:8001
        ,
        else => null,
    };
}

/// Parse an EKS cluster name from an exec-credential args slice.
/// Looks for `--cluster-name <value>` and returns the value, or null if absent.
pub fn eksClusterNameFromArgs(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cluster-name")) return args[i + 1];
    }
    return null;
}

/// Owns all resources that `fromKubeconfig` produces.
///
/// Lifetime contract:
///   - `namespace` borrows from `kubeconfig` (valid until `deinit`).
///   - `client` borrows its CA data from `kubeconfig.tls_config.ca_cert_data`
///     (valid until `deinit`).
///   - `client.api_server`, `client.token`, and `client.namespace` are duped
///     by `K8sClient.init`, so they are independent of `kubeconfig`.
///
/// Call `deinit()` when done.  Do NOT call `client.deinit()` separately.
pub const Bootstrapped = struct {
    client: klient.K8sClient,
    /// Borrows from `kubeconfig` when built via `fromKubeconfig`; owned slice
    /// (duped from the server URL) when built via `fromServer`.
    namespace: []const u8,
    /// Owns the parsed kubeconfig memory; null when built via `fromServer`.
    kubeconfig: ?Kubeconfig = null,
    /// Owns decoded PEM bytes when `certificate_authority_data` was base64-decoded.
    ca_pem_owned: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Bootstrapped) void {
        // Client first: it may hold a TLS bundle built from kubeconfig CA data.
        // Free it before the kubeconfig memory it borrowed from.
        self.client.deinit();
        if (self.ca_pem_owned) |pem| self.allocator.free(pem);
        if (self.kubeconfig) |*kc| kc.deinit(self.allocator);
    }
};

/// Decode kubeconfig `certificate-authority-data` (base64 PEM) into raw PEM bytes,
/// or dupe raw PEM if already PEM-armored. Caller owns the returned slice.
pub fn decodeCaCertData(allocator: std.mem.Allocator, ca_data: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, ca_data, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "-----BEGIN")) {
        return allocator.dupe(u8, trimmed);
    }
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(trimmed);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, trimmed);
    return decoded;
}

/// Build an authenticated K8sClient from the current kubeconfig context.
///
/// `context_override` selects a named context; null uses current-context.
///
/// Callers own the returned `Bootstrapped` and must call `boot.deinit()` when
/// done.  Do NOT call `boot.client.deinit()` separately — `deinit()` handles
/// the full teardown in the correct order (client before kubeconfig).
pub fn fromKubeconfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    context_override: ?[]const u8,
) !Bootstrapped {
    // ---- 1. Parse kubeconfig ----
    var parser = klient.KubeconfigParser.init(allocator, io);
    var kc = try parser.load();
    // NOTE: no `defer kc.deinit` here — ownership transfers to Bootstrapped.
    // On error paths below we deinit explicitly before returning the error.
    errdefer kc.deinit(allocator);

    // ---- 2. Resolve context ----
    const context = (if (context_override) |n|
        kc.getContextByName(n)
    else
        kc.getCurrentContext()) orelse return error.NoContext;

    // ---- 3. Resolve cluster + user ----
    const cluster = kc.getClusterByName(context.cluster) orelse return error.NoCluster;
    const user = kc.getUserByName(context.user) orelse return error.NoUser;
    try checkSupported(cluster, user);

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
    //
    // LIFETIME: tls_cfg.ca_cert_data BORROWS from kc (cluster slice).
    // K8sClient.init reads ca_cert_data to populate the TLS bundle but does NOT
    // dupe the PEM bytes itself — it writes them to a temp file and reads them
    // back into the bundle.  The client therefore does NOT hold a live pointer to
    // ca_cert_data after init returns, so in practice the dangle is already
    // inert.  Nevertheless, kc must outlive the client for correctness of any
    // future code paths that re-inspect tls_config, so we keep the ownership
    // model intact.
    var ca_pem_owned: ?[]u8 = null;
    errdefer if (ca_pem_owned) |pem| allocator.free(pem);

    const tls_cfg: ?klient.TlsConfig = if (cluster.certificate_authority_data) |ca| blk: {
        const pem = try decodeCaCertData(allocator, ca);
        ca_pem_owned = pem;
        break :blk .{ .ca_cert_data = pem };
    } else if (cluster.certificate_authority) |ca_path|
        .{ .ca_cert_path = ca_path }
    else
        null;

    // ---- 6. Build client ----
    // `ns` borrows from kc.  It outlives the function call because kc is now
    // stored in Bootstrapped rather than freed on return.
    //
    // K8sClient.init dupes `server` (line: `try allocator.dupe(u8, config.server)`)
    // and `token` (line: `if (config.token) |t| try allocator.dupe(u8, t)`) and
    // `namespace` (line: `try allocator.dupe(u8, config.namespace orelse "default")`).
    // Those fields are therefore safe after exec_cred is deinit'd and regardless
    // of the lifetime of kc.
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
        .kubeconfig = kc,
        .ca_pem_owned = ca_pem_owned,
        .allocator = allocator,
    };
}

/// Build a K8sClient pointed directly at a `kubectl proxy` URL.
///
/// No kubeconfig is parsed, no token is used, no TLS is configured.
/// `server_url` is typically "http://127.0.0.1:8001".
/// `namespace` is used as-is (caller supplies a default if needed).
///
/// Callers own the returned `Bootstrapped` and must call `boot.deinit()`.
pub fn fromServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    server_url: []const u8,
    namespace: []const u8,
) !Bootstrapped {
    const client = try klient.K8sClient.init(allocator, io, .{
        .server = server_url,
        .token = null,
        .namespace = namespace,
        .tls_config = null,
    });
    return .{ .client = client, .namespace = namespace, .kubeconfig = null, .allocator = allocator };
}
