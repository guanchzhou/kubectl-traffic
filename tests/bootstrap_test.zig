const std = @import("std");
const bootstrap = @import("bootstrap");

test "eks cluster name parsed from exec args" {
    const args = [_][]const u8{ "eks", "get-token", "--cluster-name", "test-cluster", "--region", "us-east-1" };
    try std.testing.expectEqualStrings("test-cluster", bootstrap.eksClusterNameFromArgs(&args).?);
}

test "eks cluster name absent returns null" {
    const args = [_][]const u8{ "eks", "get-token" };
    try std.testing.expect(bootstrap.eksClusterNameFromArgs(&args) == null);
}

test "decodeCaCertData decodes base64 PEM and passes through raw PEM" {
    const raw_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";
    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, raw_pem);

    const decoded = try bootstrap.decodeCaCertData(std.testing.allocator, b64);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(raw_pem, decoded);

    const passthrough = try bootstrap.decodeCaCertData(std.testing.allocator, raw_pem);
    defer std.testing.allocator.free(passthrough);
    try std.testing.expectEqualStrings(raw_pem, passthrough);
}

test "client-certificate kubeconfig is rejected up front with a clear message" {
    const cluster: bootstrap.Cluster = .{ .name = "c", .server = "https://k8s.example:6443", .certificate_authority_data = "x" };
    const user: bootstrap.User = .{ .name = "u", .client_certificate_data = "Y2VydA==", .client_key_data = "a2V5" };
    const err = bootstrap.checkSupported(cluster, user);
    try std.testing.expectError(error.ClientCertificatesUnsupported, err);
    const msg = bootstrap.unsupportedMessage(error.ClientCertificatesUnsupported).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "kubectl proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--server") != null);

    const path_user: bootstrap.User = .{ .name = "u", .client_certificate = "/tmp/c.crt", .client_key = "/tmp/c.key" };
    try std.testing.expectError(error.ClientCertificatesUnsupported, bootstrap.checkSupported(cluster, path_user));
}

test "client certificate alongside a token falls back to the token" {
    const cluster: bootstrap.Cluster = .{ .name = "c", .server = "https://k8s.example:6443" };
    const user: bootstrap.User = .{ .name = "u", .token = "t", .client_certificate_data = "Y2VydA==" };
    try bootstrap.checkSupported(cluster, user);
}

test "insecure-skip-tls-verify is rejected with a clear message" {
    const cluster: bootstrap.Cluster = .{ .name = "c", .server = "https://k8s.example:6443", .insecure_skip_tls_verify = true };
    const user: bootstrap.User = .{ .name = "u", .token = "t" };
    try std.testing.expectError(error.InsecureSkipVerifyUnsupported, bootstrap.checkSupported(cluster, user));
    try std.testing.expect(std.mem.indexOf(u8, bootstrap.unsupportedMessage(error.InsecureSkipVerifyUnsupported).?, "kubectl proxy") != null);
    try std.testing.expect(bootstrap.unsupportedMessage(error.OutOfMemory) == null);
}
