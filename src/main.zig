const std = @import("std");

pub fn main() !void {
    std.debug.print("kubectl-traffic\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
