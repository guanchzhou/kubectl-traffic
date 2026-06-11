const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const klient = b.dependency("zig_klient", .{ .target = target, .optimize = optimize });
    const klient_mod = klient.module("klient");

    // ---- shared source modules ----
    const cli_mod = b.createModule(.{ .root_source_file = b.path("src/cli.zig"), .target = target, .optimize = optimize });
    const promql_mod = b.createModule(.{ .root_source_file = b.path("src/promql.zig"), .target = target, .optimize = optimize });
    const prom_client_mod = b.createModule(.{ .root_source_file = b.path("src/prom_client.zig"), .target = target, .optimize = optimize });
    prom_client_mod.addImport("klient", klient_mod);
    const model_mod = b.createModule(.{ .root_source_file = b.path("src/model.zig"), .target = target, .optimize = optimize });
    const fmt_mod = b.createModule(.{ .root_source_file = b.path("src/render/format.zig"), .target = target, .optimize = optimize });
    const spark_mod = b.createModule(.{ .root_source_file = b.path("src/render/sparkline.zig"), .target = target, .optimize = optimize });
    const bar_mod = b.createModule(.{ .root_source_file = b.path("src/render/bar.zig"), .target = target, .optimize = optimize });
    const line_mod = b.createModule(.{ .root_source_file = b.path("src/render/line.zig"), .target = target, .optimize = optimize });
    line_mod.addImport("render_format", fmt_mod);
    const table_mod = b.createModule(.{ .root_source_file = b.path("src/render/table.zig"), .target = target, .optimize = optimize });
    table_mod.addImport("model", model_mod);
    table_mod.addImport("render_line", line_mod);
    table_mod.addImport("render_format", fmt_mod);
    table_mod.addImport("render_sparkline", spark_mod);
    table_mod.addImport("render_bar", bar_mod);
    const graph_mod = b.createModule(.{ .root_source_file = b.path("src/render/graph.zig"), .target = target, .optimize = optimize });
    graph_mod.addImport("model", model_mod);
    graph_mod.addImport("render_line", line_mod);
    graph_mod.addImport("render_format", fmt_mod);

    const discovery_mod = b.createModule(.{ .root_source_file = b.path("src/discovery.zig"), .target = target, .optimize = optimize });
    discovery_mod.addImport("klient", klient_mod);

    const tui_mod = b.createModule(.{ .root_source_file = b.path("src/render/tui.zig"), .target = target, .optimize = optimize });
    tui_mod.addImport("render_line", line_mod);

    const app_mod = b.createModule(.{ .root_source_file = b.path("src/app.zig"), .target = target, .optimize = optimize });
    app_mod.addImport("klient", klient_mod);
    app_mod.addImport("model", model_mod);
    app_mod.addImport("promql", promql_mod);
    app_mod.addImport("prom_client", prom_client_mod);
    app_mod.addImport("discovery", discovery_mod);
    app_mod.addImport("render_graph", graph_mod);
    app_mod.addImport("render_table", table_mod);
    app_mod.addImport("render_tui", tui_mod);

    const bootstrap_mod = b.createModule(.{ .root_source_file = b.path("src/bootstrap.zig"), .target = target, .optimize = optimize });
    bootstrap_mod.addImport("klient", klient_mod);

    const target_mod = b.createModule(.{ .root_source_file = b.path("src/target.zig"), .target = target, .optimize = optimize });
    target_mod.addImport("cli", cli_mod);
    target_mod.addImport("klient", klient_mod);

    const exe = b.addExecutable(.{
        .name = "kubectl-traffic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("klient", klient_mod);
    exe.root_module.addImport("cli", cli_mod);
    exe.root_module.addImport("bootstrap", bootstrap_mod);
    exe.root_module.addImport("discovery", discovery_mod);
    exe.root_module.addImport("target", target_mod);
    exe.root_module.addImport("app", app_mod);
    exe.root_module.addImport("render_tui", tui_mod);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("klient", klient_mod);
    tests.root_module.addImport("target", target_mod);
    tests.root_module.addImport("cli", cli_mod);
    tests.root_module.addImport("promql", promql_mod);
    tests.root_module.addImport("prom_client", prom_client_mod);
    tests.root_module.addImport("model", model_mod);
    tests.root_module.addImport("render_format", fmt_mod);
    tests.root_module.addImport("render_sparkline", spark_mod);
    tests.root_module.addImport("render_bar", bar_mod);
    tests.root_module.addImport("render_line", line_mod);
    tests.root_module.addImport("render_table", table_mod);
    tests.root_module.addImport("render_graph", graph_mod);
    tests.root_module.addImport("discovery", discovery_mod);
    tests.root_module.addImport("bootstrap", bootstrap_mod);
    tests.root_module.addImport("app", app_mod);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
