const std = @import("std");
const fmtmod = @import("render_format");

pub const Color = enum { default, dim, green, yellow, red, cyan };

pub fn colorForHealth(h: fmtmod.Health) Color {
    return switch (h) {
        .good => .green,
        .warn => .yellow,
        .bad => .red,
    };
}

pub const Span = struct {
    text: []const u8, // owned
    color: Color = .default,
};

pub const StyledLine = struct {
    spans: []Span, // owned

    pub fn plainText(self: StyledLine, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        for (self.spans) |s| try out.appendSlice(allocator, s.text);
        return out.toOwnedSlice(allocator);
    }
};
