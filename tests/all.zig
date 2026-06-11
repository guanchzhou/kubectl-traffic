// tests/all.zig — aggregate test root; import every test file here going forward
comptime {
    _ = @import("cli_test.zig");
    _ = @import("smoke_test.zig");
    _ = @import("promql_test.zig");
    _ = @import("prom_client_test.zig");
    _ = @import("model_test.zig");
    _ = @import("render_primitives_test.zig");
    _ = @import("table_test.zig");
    _ = @import("graph_test.zig");
    _ = @import("target_test.zig");
    _ = @import("proxy_path_test.zig");
    _ = @import("discovery_test.zig");
    _ = @import("bootstrap_test.zig");
}
