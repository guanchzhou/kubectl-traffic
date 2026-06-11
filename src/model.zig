const std = @import("std");

pub const Direction = enum { inbound, outbound };

pub const Peer = struct {
    name: []const u8, // owned
    namespace: []const u8, // owned
    dir: Direction,
    req_per_s: f64 = 0,
    err_per_s: f64 = 0,
    p50_ms: f64 = 0,
    p99_ms: f64 = 0,
    hist: []f64, // ring buffer, owned
    hist_lin: []f64, // linearization scratch, owned, same cap
    hist_len: usize = 0,
    hist_head: usize = 0,
    cap: usize,

    pub fn successPercent(self: Peer) f64 {
        if (self.req_per_s <= 0) return 100.0;
        const ok = (1.0 - (self.err_per_s / self.req_per_s)) * 100.0;
        return std.math.clamp(ok, 0.0, 100.0);
    }

    fn push(self: *Peer, v: f64) void {
        const idx = (self.hist_head + self.hist_len) % self.cap;
        if (self.hist_len < self.cap) {
            self.hist[idx] = v;
            self.hist_len += 1;
        } else {
            self.hist[self.hist_head] = v;
            self.hist_head = (self.hist_head + 1) % self.cap;
        }
    }

    /// Linearized history oldest..newest. Valid until the next push/commitTick.
    pub fn history(self: *Peer) []f64 {
        var i: usize = 0;
        while (i < self.hist_len) : (i += 1) {
            self.hist_lin[i] = self.hist[(self.hist_head + i) % self.cap];
        }
        return self.hist_lin[0..self.hist_len];
    }
};

pub const TrafficModel = struct {
    allocator: std.mem.Allocator,
    cap: usize,
    peers: std.ArrayList(*Peer),

    pub fn init(allocator: std.mem.Allocator, history_cap: usize) TrafficModel {
        return .{ .allocator = allocator, .cap = history_cap, .peers = .empty };
    }

    pub fn deinit(self: *TrafficModel) void {
        for (self.peers.items) |p| {
            self.allocator.free(p.name);
            self.allocator.free(p.namespace);
            self.allocator.free(p.hist);
            self.allocator.free(p.hist_lin);
            self.allocator.destroy(p);
        }
        self.peers.deinit(self.allocator);
    }

    fn find(self: *TrafficModel, dir: Direction, name: []const u8) ?*Peer {
        for (self.peers.items) |p| {
            if (p.dir == dir and std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    fn getOrCreate(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8) !*Peer {
        if (self.find(dir, name)) |p| return p;
        const p = try self.allocator.create(Peer);
        p.* = .{
            .name = try self.allocator.dupe(u8, name),
            .namespace = try self.allocator.dupe(u8, ns),
            .dir = dir,
            .hist = try self.allocator.alloc(f64, self.cap),
            .hist_lin = try self.allocator.alloc(f64, self.cap),
            .cap = self.cap,
        };
        try self.peers.append(self.allocator, p);
        return p;
    }

    pub fn setRate(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8, v: f64) !void {
        (try self.getOrCreate(dir, name, ns)).req_per_s = v;
    }

    pub fn setErrorRate(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8, v: f64) !void {
        (try self.getOrCreate(dir, name, ns)).err_per_s = v;
    }

    pub fn setLatency(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8, p50: f64, p99: f64) !void {
        const p = try self.getOrCreate(dir, name, ns);
        p.p50_ms = p50;
        p.p99_ms = p99;
    }

    pub fn peer(self: *TrafficModel, dir: Direction, name: []const u8) ?*Peer {
        return self.find(dir, name);
    }

    /// Push the current req_per_s of every peer into its history ring.
    pub fn commitTick(self: *TrafficModel) void {
        for (self.peers.items) |p| p.push(p.req_per_s);
    }

    pub fn totalRate(self: *TrafficModel, dir: Direction) f64 {
        var sum: f64 = 0;
        for (self.peers.items) |p| if (p.dir == dir) {
            sum += p.req_per_s;
        };
        return sum;
    }

    /// Caller frees the returned slice (not the Peers).
    pub fn topN(self: *TrafficModel, allocator: std.mem.Allocator, dir: Direction, n: usize) ![]*Peer {
        var list = std.ArrayList(*Peer).empty;
        defer list.deinit(allocator);
        for (self.peers.items) |p| if (p.dir == dir) try list.append(allocator, p);
        std.mem.sort(*Peer, list.items, {}, struct {
            fn lt(_: void, a: *Peer, b: *Peer) bool {
                return a.req_per_s > b.req_per_s;
            }
        }.lt);
        const take = @min(n, list.items.len);
        return allocator.dupe(*Peer, list.items[0..take]);
    }
};
