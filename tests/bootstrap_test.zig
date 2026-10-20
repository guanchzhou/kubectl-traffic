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
