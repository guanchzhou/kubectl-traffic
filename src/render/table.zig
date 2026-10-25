const std = @import("std");
const model = @import("model");
const line = @import("render_line");
const fmtmod = @import("render_format");
const spark = @import("render_sparkline");
const bar = @import("render_bar");

const StyledLine = line.StyledLine;
const Span = line.Span;

fn dupSpan(a: std.mem.Allocator, text: []const u8, color: line.Color) !Span {
    return .{ .text = try line.sanitizeAlloc(a, text, line.max_span_len), .color = color };
}

fn header(a: std.mem.Allocator, title: []const u8) !StyledLine {
    var spans = try a.alloc(Span, 1);
    spans[0] = try dupSpan(a, title, .cyan);
    return .{ .spans = spans };
}

fn peerRow(a: std.mem.Allocator, p: *model.Peer, max_rate: f64) !StyledLine {
    var rbuf: [16]u8 = undefined;
    var sbuf: [256]u8 = undefined;
    var bbuf: [128]u8 = undefined;
    var p99buf: [16]u8 = undefined;
    var pctbuf: [16]u8 = undefined;

    const rate_s = try fmtmod.rate(&rbuf, p.req_per_s);
    const trend = try spark.render(&sbuf, p.history());
    const load = try bar.render(&bbuf, p.req_per_s, max_rate, 7);
    const p99_s = try fmtmod.latencyMs(&p99buf, p.p99_ms);
    const pct_s = try fmtmod.percent(&pctbuf, p.successPercent());

    var spans = try a.alloc(Span, 6);
    spans[0] = try dupSpan(a, p.name, .default);
    spans[1] = try dupSpan(a, rate_s, .default);
    spans[2] = try dupSpan(a, trend, .dim);
    spans[3] = try dupSpan(a, load, .cyan);
    spans[4] = try dupSpan(a, pct_s, line.colorForHealth(fmtmod.health(p.successPercent())));
    spans[5] = try dupSpan(a, p99_s, .default);
    return .{ .spans = spans };
}

pub fn render(a: std.mem.Allocator, m: *model.TrafficModel) ![]StyledLine {
    var lines = std.ArrayList(StyledLine).empty;
    errdefer {
        for (lines.items) |ln| {
            for (ln.spans) |s| a.free(s.text);
            a.free(ln.spans);
        }
        lines.deinit(a);
    }

    const dirs = [_]model.Direction{ .inbound, .outbound };
    const titles = [_][]const u8{ "INBOUND", "OUTBOUND" };
    for (dirs, titles) |dir, title| {
        try lines.append(a, try header(a, title));
        const max_rate = m.totalRate(dir);
        for (m.peers.items) |p| {
            if (p.dir != dir) continue;
            try lines.append(a, try peerRow(a, p, max_rate));
        }
    }
    return lines.toOwnedSlice(a);
}

pub fn freeLines(a: std.mem.Allocator, lines: []StyledLine) void {
    for (lines) |ln| {
        for (ln.spans) |s| a.free(s.text);
        a.free(ln.spans);
    }
    a.free(lines);
}
