const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const klient = b.dependency("zig_klient", .{ .target = target, .optimize = optimize });
    const klient_mod = klient.module("klient");

    const exe = b.addExecutable(.{
        .name = "kubectl-traffic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("klient", klient_mod);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("klient", klient_mod);
    tests.root_module.addImport("cli", b.createModule(.{ .root_source_file = b.path("src/cli.zig") }));
    tests.root_module.addImport("promql", b.createModule(.{ .root_source_file = b.path("src/promql.zig") }));
    tests.root_module.addImport("prom_client", b.createModule(.{ .root_source_file = b.path("src/prom_client.zig") }));
    tests.root_module.addImport("model", b.createModule(.{ .root_source_file = b.path("src/model.zig") }));
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
