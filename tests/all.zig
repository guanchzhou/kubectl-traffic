// tests/all.zig — aggregate test root; import every test file here going forward
comptime {
    _ = @import("cli_test.zig");
    _ = @import("smoke_test.zig");
    _ = @import("promql_test.zig");
}
