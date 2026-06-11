const std = @import("std");
const model = @import("model");
const line = @import("render_line");
const fmtmod = @import("render_format");

const StyledLine = line.StyledLine;
const Span = line.Span;

fn lineOf(a: std.mem.Allocator, text: []const u8, color: line.Color) !StyledLine {
    const spans = try a.alloc(Span, 1);
    spans[0] = .{ .text = try a.dupe(u8, text), .color = color };
    return .{ .spans = spans };
}

fn freePartial(a: std.mem.Allocator, items: []StyledLine) void {
    for (items) |ln| {
        for (ln.spans) |s| a.free(s.text);
        a.free(ln.spans);
    }
}

const NAME_CAP: usize = 34;

fn pad(a: std.mem.Allocator, list: *std.ArrayList(u8), c: u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try list.append(a, c);
}

fn appendLeft(a: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    const n = @min(text.len, width);
    try list.appendSlice(a, text[0..n]);
    try pad(a, list, ' ', width - n);
}

fn appendRight(a: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    const n = @min(text.len, width);
    try pad(a, list, ' ', width - n);
    try list.appendSlice(a, text[0..n]);
}

fn appendCenter(a: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    const n = @min(text.len, width);
    const left = (width - n) / 2;
    try pad(a, list, ' ', left);
    try list.appendSlice(a, text[0..n]);
    try pad(a, list, ' ', width - n - left);
}

const HBAR = "\u{2500}"; // ─
const VBAR = "\u{2502}"; // │
const TL = "\u{250C}"; // ┌
const TR = "\u{2510}"; // ┐
const BL = "\u{2514}"; // └
const BR = "\u{2518}"; // ┘
const RARROW = "\u{25B6}"; // ▶

/// Boxed topology:
///   callers (left, arrows in) --> [ target box ] --> callees (right, arrows out)
/// Arrowheads align to the box's left edge; the box spans the body rows.
pub fn render(a: std.mem.Allocator, m: *model.TrafficModel, target: []const u8, ns: []const u8, top: usize) ![]StyledLine {
    var lines = std.ArrayList(StyledLine).empty;
    errdefer {
        freePartial(a, lines.items);
        lines.deinit(a);
    }

    const in = try m.topN(a, .inbound, top);
    defer a.free(in);
    const out = try m.topN(a, .outbound, top);
    defer a.free(out);

    // ---- left column geometry (inbound "name  rate r/s") ----
    var name_w: usize = 0;
    var rate_w: usize = 1;
    var rb: [16]u8 = undefined;
    for (in) |p| {
        name_w = @max(name_w, @min(p.name.len, NAME_CAP));
        const rs = try fmtmod.rate(&rb, p.req_per_s);
        rate_w = @max(rate_w, rs.len);
    }
    const has_in = in.len > 0;
    // left cell visual width = name + ' ' + rate + " r/s"
    const left_w: usize = if (has_in) name_w + 1 + rate_w + 4 else 0;
    // arrow connector " ──▶" = 4 visual cols (space + ─ + ─ + ▶); when no inbound, "  "
    const arrow_cols: usize = if (has_in) 4 else 2;
    const box_left_col = left_w + arrow_cols;

    // ---- box interior width ----
    var tb: [96]u8 = undefined;
    const totals = try std.fmt.bufPrint(&tb, "{d:.1} in / {d:.1} out r/s", .{ m.totalRate(.inbound), m.totalRate(.outbound) });
    var bw: usize = @max(target.len, totals.len) + 2;
    if (bw < 10) bw = 10;

    // ---- rows: enough for inbound, outbound, and box content (name + totals) ----
    const body_rows = @max(@max(in.len, out.len), @as(usize, 2));
    const name_row: usize = (body_rows - 1) / 2;
    const totals_row: usize = if (name_row + 1 < body_rows) name_row + 1 else name_row;

    // ---- top border ----
    {
        var t = std.ArrayList(u8).empty;
        defer t.deinit(a);
        try pad(a, &t, ' ', box_left_col);
        try t.appendSlice(a, TL);
        var i: usize = 0;
        while (i < bw) : (i += 1) try t.appendSlice(a, HBAR);
        try t.appendSlice(a, TR);
        try lines.append(a, try lineOf(a, t.items, .cyan));
    }

    // ---- body rows ----
    var row: usize = 0;
    while (row < body_rows) : (row += 1) {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(a);

        if (has_in) {
            if (row < in.len) {
                const p = in[row];
                try appendLeft(a, &b, p.name, name_w);
                try b.append(a, ' ');
                const rs = try fmtmod.rate(&rb, p.req_per_s);
                try appendRight(a, &b, rs, rate_w);
                try b.appendSlice(a, " r/s");
                try b.append(a, ' ');
                try b.appendSlice(a, HBAR);
                try b.appendSlice(a, HBAR);
                try b.appendSlice(a, RARROW); // " ──▶"
            } else {
                try pad(a, &b, ' ', left_w + arrow_cols);
            }
        } else {
            try pad(a, &b, ' ', arrow_cols);
        }

        // box left edge
        try b.appendSlice(a, VBAR);
        // interior
        if (row == name_row) {
            try appendCenter(a, &b, target, bw);
        } else if (row == totals_row) {
            try appendCenter(a, &b, totals, bw);
        } else {
            try pad(a, &b, ' ', bw);
        }
        // box right edge
        try b.appendSlice(a, VBAR);

        // outbound on the right
        if (row < out.len) {
            const p = out[row];
            try b.appendSlice(a, HBAR);
            try b.appendSlice(a, HBAR);
            try b.appendSlice(a, RARROW);
            try b.append(a, ' ');
            try b.appendSlice(a, p.name);
            try b.append(a, ' ');
            const rs = try fmtmod.rate(&rb, p.req_per_s);
            try b.appendSlice(a, rs);
            try b.appendSlice(a, " r/s");
        }

        try lines.append(a, try lineOf(a, b.items, .default));
    }

    // ---- bottom border ----
    {
        var t = std.ArrayList(u8).empty;
        defer t.deinit(a);
        try pad(a, &t, ' ', box_left_col);
        try t.appendSlice(a, BL);
        var i: usize = 0;
        while (i < bw) : (i += 1) try t.appendSlice(a, HBAR);
        try t.appendSlice(a, BR);
        try lines.append(a, try lineOf(a, t.items, .cyan));
    }

    // ---- footer: totals + namespace ----
    {
        var f = std.ArrayList(u8).empty;
        defer f.deinit(a);
        var fb: [128]u8 = undefined;
        const ftxt = try std.fmt.bufPrint(&fb, "{d:.1} r/s in   ns:{s}   {d:.1} r/s out", .{ m.totalRate(.inbound), ns, m.totalRate(.outbound) });
        try f.appendSlice(a, ftxt);
        try lines.append(a, try lineOf(a, f.items, .dim));
    }

    return lines.toOwnedSlice(a);
}

pub fn freeLines(a: std.mem.Allocator, lines: []StyledLine) void {
    freePartial(a, lines);
    a.free(lines);
}
