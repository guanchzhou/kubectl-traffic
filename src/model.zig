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
    idle_ticks: usize = 0, // consecutive committed ticks with req_per_s == 0

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
    /// Peers idle for this many consecutive ticks are dropped; 0 disables pruning.
    prune_after: usize = default_prune_after,

    pub const default_prune_after: usize = 30;

    pub fn init(allocator: std.mem.Allocator, history_cap: usize) TrafficModel {
        return .{ .allocator = allocator, .cap = history_cap, .peers = .empty };
    }

    pub fn deinit(self: *TrafficModel) void {
        for (self.peers.items) |p| self.destroyPeer(p);
        self.peers.deinit(self.allocator);
    }

    fn destroyPeer(self: *TrafficModel, p: *Peer) void {
        self.allocator.free(p.name);
        self.allocator.free(p.namespace);
        self.allocator.free(p.hist);
        self.allocator.free(p.hist_lin);
        self.allocator.destroy(p);
    }

    fn find(self: *TrafficModel, dir: Direction, name: []const u8) ?*Peer {
        for (self.peers.items) |p| {
            if (p.dir == dir and std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    fn findInNamespace(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8) ?*Peer {
        for (self.peers.items) |p| {
            if (p.dir == dir and std.mem.eql(u8, p.name, name) and std.mem.eql(u8, p.namespace, ns)) return p;
        }
        return null;
    }

    fn getOrCreate(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8) !*Peer {
        if (self.findInNamespace(dir, name, ns)) |p| return p;
        const p = try self.allocator.create(Peer);
        errdefer self.allocator.destroy(p);
        const dup_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(dup_name);
        const dup_ns = try self.allocator.dupe(u8, ns);
        errdefer self.allocator.free(dup_ns);
        const hist = try self.allocator.alloc(f64, self.cap);
        errdefer self.allocator.free(hist);
        const hist_lin = try self.allocator.alloc(f64, self.cap);
        errdefer self.allocator.free(hist_lin);
        p.* = .{
            .name = dup_name,
            .namespace = dup_ns,
            .dir = dir,
            .hist = hist,
            .hist_lin = hist_lin,
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

    /// Accumulate request and 5xx rates; used when one query returns several
    /// series per peer (e.g. split by response class).
    pub fn addRates(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8, req: f64, err: f64) !void {
        const p = try self.getOrCreate(dir, name, ns);
        p.req_per_s += req;
        p.err_per_s += err;
    }

    pub fn setLatency(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8, p50: f64, p99: f64) !void {
        const p = try self.getOrCreate(dir, name, ns);
        p.p50_ms = p50;
        p.p99_ms = p99;
    }

    pub fn peer(self: *TrafficModel, dir: Direction, name: []const u8) ?*Peer {
        return self.find(dir, name);
    }

    pub fn peerInNamespace(self: *TrafficModel, dir: Direction, name: []const u8, ns: []const u8) ?*Peer {
        return self.findInNamespace(dir, name, ns);
    }

    /// Zero transient per-tick metrics before folding a new scrape so peers that
    /// disappeared from the latest instant vector decay to 0 instead of freezing.
    pub fn beginTick(self: *TrafficModel) void {
        for (self.peers.items) |p| {
            p.req_per_s = 0;
            p.err_per_s = 0;
            p.p50_ms = 0;
            p.p99_ms = 0;
        }
    }

    /// Push the current req_per_s of every peer into its history ring, then
    /// drop peers that have been idle for `prune_after` consecutive ticks.
    /// Invalidates `*Peer` pointers to pruned peers.
    pub fn commitTick(self: *TrafficModel) void {
        var i: usize = 0;
        while (i < self.peers.items.len) {
            const p = self.peers.items[i];
            p.push(p.req_per_s);
            p.idle_ticks = if (p.req_per_s == 0) p.idle_ticks + 1 else 0;
            if (self.prune_after != 0 and p.idle_ticks >= self.prune_after) {
                _ = self.peers.orderedRemove(i);
                self.destroyPeer(p);
                continue;
            }
            i += 1;
        }
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
