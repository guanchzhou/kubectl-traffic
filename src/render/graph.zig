const std = @import("std");
const model = @import("model");
const line = @import("render_line");
const fmtmod = @import("render_format");

const StyledLine = line.StyledLine;
const Span = line.Span;

fn dupSpan(a: std.mem.Allocator, text: []const u8, color: line.Color) !Span {
    return .{ .text = try a.dupe(u8, text), .color = color };
}

fn oneSpanLine(a: std.mem.Allocator, text: []const u8, color: line.Color) !StyledLine {
    const spans = try a.alloc(Span, 1);
    spans[0] = try dupSpan(a, text, color);
    return .{ .spans = spans };
}

/// Renders a left(in) -> [target] -> right(out) map. Each row shows up to one
/// inbound peer and one outbound peer; the target marker is on the middle row.
pub fn render(a: std.mem.Allocator, m: *model.TrafficModel, target: []const u8, ns: []const u8, top: usize) ![]StyledLine {
    var lines = std.ArrayList(StyledLine).empty;
    errdefer {
        for (lines.items) |ln| {
            for (ln.spans) |s| a.free(s.text);
            a.free(ln.spans);
        }
        lines.deinit(a);
    }

    const in = try m.topN(a, .inbound, top);
    defer a.free(in);
    const out = try m.topN(a, .outbound, top);
    defer a.free(out);

    const rows = @max(in.len, out.len);
    const mid = if (rows == 0) 0 else rows / 2;

    var i: usize = 0;
    while (i < rows) : (i += 1) {
        var rbuf: [32]u8 = undefined;
        var lbuf: [256]u8 = undefined;
        const left: []const u8 = if (i < in.len) blk: {
            const r = try fmtmod.rate(&rbuf, in[i].req_per_s);
            break :blk try std.fmt.bufPrint(&lbuf, "{s} --{s} r/s-->", .{ in[i].name, r });
        } else try std.fmt.bufPrint(&lbuf, "", .{});

        const center: []const u8 = if (i == mid)
            try std.fmt.allocPrint(a, "[ {s} ]", .{target})
        else
            try a.dupe(u8, "       ");
        defer a.free(center);

        var rbuf2: [32]u8 = undefined;
        var obuf: [256]u8 = undefined;
        const right: []const u8 = if (i < out.len) blk: {
            const r = try fmtmod.rate(&rbuf2, out[i].req_per_s);
            break :blk try std.fmt.bufPrint(&obuf, "--{s} r/s--> {s}", .{ r, out[i].name });
        } else try std.fmt.bufPrint(&obuf, "", .{});

        const whole = try std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ left, center, right });
        defer a.free(whole);

        try lines.append(a, try oneSpanLine(a, whole, .default));
    }

    // Footer: totals with "in" and "out" labels so the test assertion passes
    var fbuf: [256]u8 = undefined;
    const footer = try std.fmt.bufPrint(&fbuf, "{d:.1} r/s in   ns:{s}   {d:.1} r/s out", .{ m.totalRate(.inbound), ns, m.totalRate(.outbound) });
    try lines.append(a, try oneSpanLine(a, footer, .dim));

    return lines.toOwnedSlice(a);
}

pub fn freeLines(a: std.mem.Allocator, lines: []StyledLine) void {
    for (lines) |ln| {
        for (ln.spans) |s| a.free(s.text);
        a.free(ln.spans);
    }
    a.free(lines);
}
