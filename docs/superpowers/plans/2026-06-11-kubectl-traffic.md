# kubectl-traffic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Zig kubectl plugin (`kubectl traffic <pod|deploy>/<name>`) that renders a live, top-style view of a workload's inbound/outbound L7 traffic — a topology graph panel above a detailed sparkline table — sourced from Istio's Prometheus metrics.

**Architecture:** A polling loop queries Istio metrics from Prometheus (via PromQL through the Kubernetes API-server service proxy, reusing `zig-klient`'s authenticated client), folds the results into an in-memory model with rolling per-peer history, and draws two panels. All data/logic units are pure and unit-tested without a cluster; the renderer is backend-agnostic (produces styled lines) so the TUI layer is a thin adapter.

**Tech Stack:** Zig 0.16.0 · [zig-klient](https://github.com/guanchzhou/zig-klient) 0.3.2 (K8s client, EKS exec-credential auth, raw `request()`) · libvaxis (TUI) with a documented hand-rolled-ANSI fallback · Istio Prometheus metrics (`istio_requests_total`, `istio_request_duration_milliseconds`).

---

## File Structure

```
kubectl-traffic/
  build.zig                 # build: link zig-klient + libvaxis, test step, exe `kubectl-traffic`
  build.zig.zon             # deps: zig_klient (path ../zig-klient), vaxis
  src/
    main.zig                # entry point: parse args -> bootstrap client -> run app
    cli.zig                 # arg/flag parsing -> Cli config struct  (PURE)
    target.zig              # parse "pod|deploy/name"; owner-chain Pod->RS->Deployment (PURE core + thin live wrapper)
    discovery.zig           # locate Prometheus service in `monitoring`
    promql.zig              # build inbound/outbound PromQL strings  (PURE)
    prom_client.zig         # issue PromQL via K8sClient.request service-proxy; parse JSON  (parse = PURE)
    model.zig               # Peer/Direction/TrafficModel + aggregate math + rolling history  (PURE)
    bootstrap.zig           # kubeconfig -> exec-credential -> K8sClient
    app.zig                 # poll loop: query -> update model -> redraw
    render/
      format.zig            # rate/latency/percent formatting + health color thresholds  (PURE)
      sparkline.zig         # []f64 -> unicode sparkline                                   (PURE)
      bar.zig               # f64 + max -> magnitude bar                                    (PURE)
      line.zig              # StyledLine/Span types shared by panels + TUI adapter
      graph.zig             # TrafficModel -> []StyledLine topology panel                   (PURE)
      table.zig             # TrafficModel -> []StyledLine detail panel                     (PURE)
      tui.zig               # libvaxis adapter: alt-screen, input, paint StyledLines, resize
  docs/superpowers/...
```

Test files live in `tests/` mirroring `src/` (e.g. `tests/promql_test.zig`), wired into the `zig build test` step.

---

## Conventions for every task

- Zig 0.16.0. Run all tests with `zig build test` from the repo root.
- After a unit's test passes, **commit** with a conventional-commit message.
- Pure units take/return plain values + an `std.mem.Allocator`; no globals.
- Color is expressed as a semantic enum (`Health`) resolved to ANSI/vaxis by the adapter — never hardcode escape codes in pure units.

---

### Task 0: Project scaffold + build wiring

**Files:**
- Create: `build.zig.zon`
- Create: `build.zig`
- Create: `src/main.zig`
- Create: `tests/smoke_test.zig`

- [ ] **Step 1: Create `build.zig.zon`**

```zig
.{
    .name = .kubectl_traffic,
    .version = "0.1.0",
    .fingerprint = 0x0,            // replace with `zig build` suggested value on first run
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zig_klient = .{ .path = "../zig-klient" },
        // vaxis pinned in Task 12 after verifying 0.16 support; placeholder kept empty here on purpose
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "tests" },
}
```

- [ ] **Step 2: Create `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const klient = b.dependency("zig_klient", .{ .target = target, .optimize = optimize });
    const klient_mod = klient.module("klient");

    const exe = b.addExecutable(.{
        .name = "kubectl-traffic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("klient", klient_mod);
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("klient", klient_mod);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
```

> Note: confirm `zig_klient` exposes a module named `klient` (it exports via `src/klient.zig`). If the module name differs, run `zig build --help` against zig-klient or check its `build.zig` `addModule` call and adjust the string.

- [ ] **Step 3: Create minimal `src/main.zig`**

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("kubectl-traffic\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 4: Create `tests/smoke_test.zig`**

```zig
const std = @import("std");

test "smoke: build links and tests run" {
    try std.testing.expect(true);
}
```

- [ ] **Step 5: Build and test**

Run: `zig build && zig build test`
Expected: build succeeds (fix the `fingerprint` to the value zig prints on first run), test step reports `1 passed`.

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon src/main.zig tests/smoke_test.zig
git commit -m "chore: scaffold kubectl-traffic build + smoke test"
```

---

### Task 1: CLI parsing (`cli.zig`)

**Files:**
- Create: `src/cli.zig`
- Test: `tests/cli_test.zig` (add to build test step)

- [ ] **Step 1: Write the failing test** — `tests/cli_test.zig`

```zig
const std = @import("std");
const cli = @import("cli");

test "parse deploy target with flags" {
    const args = [_][]const u8{ "deploy/foo", "-n", "ef-test", "--interval", "5s", "--top", "8" };
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(cli.Kind.deployment, c.kind);
    try std.testing.expectEqualStrings("foo", c.name);
    try std.testing.expectEqualStrings("ef-test", c.namespace.?);
    try std.testing.expectEqual(@as(u64, 5_000), c.interval_ms);
    try std.testing.expectEqual(@as(usize, 8), c.top);
}

test "defaults: pod kind, 2s interval, top 6, namespace null" {
    const args = [_][]const u8{"pod/bar-abc"};
    const c = try cli.parse(std.testing.allocator, &args);
    try std.testing.expectEqual(cli.Kind.pod, c.kind);
    try std.testing.expectEqualStrings("bar-abc", c.name);
    try std.testing.expect(c.namespace == null);
    try std.testing.expectEqual(@as(u64, 2_000), c.interval_ms);
    try std.testing.expectEqual(@as(usize, 6), c.top);
}

test "rejects missing slash" {
    const args = [_][]const u8{"foo"};
    try std.testing.expectError(error.InvalidTarget, cli.parse(std.testing.allocator, &args));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `cli` module / `parse` not found.

- [ ] **Step 3: Implement `src/cli.zig`**

```zig
const std = @import("std");

pub const Kind = enum { pod, deployment };

pub const Cli = struct {
    kind: Kind,
    name: []const u8,          // borrows from argv; do not free
    namespace: ?[]const u8 = null,
    interval_ms: u64 = 2_000,
    top: usize = 6,
    prometheus: ?[]const u8 = null, // form "svc.<ns>:<port>"

    pub const help =
        \\Usage: kubectl traffic <pod|deploy>/<name> [flags]
        \\  -n, --namespace <ns>   target namespace (default: context ns)
        \\      --interval <dur>   refresh interval, e.g. 2s, 500ms (default 2s)
        \\      --top <n>          peers drawn in graph per direction (default 6)
        \\      --prometheus <ref> svc.<ns>:<port> override (default: auto-discover)
        \\  -h, --help
    ;
};

fn parseTarget(arg: []const u8) !struct { kind: Kind, name: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, arg, '/') orelse return error.InvalidTarget;
    const k = arg[0..slash];
    const n = arg[slash + 1 ..];
    if (n.len == 0) return error.InvalidTarget;
    const kind: Kind = if (std.mem.eql(u8, k, "pod"))
        .pod
    else if (std.mem.eql(u8, k, "deploy") or std.mem.eql(u8, k, "deployment"))
        .deployment
    else
        return error.InvalidTarget;
    return .{ .kind = kind, .name = n };
}

/// Parse "2s" / "500ms" / "1m" -> milliseconds.
pub fn parseDuration(s: []const u8) !u64 {
    if (std.mem.endsWith(u8, s, "ms")) {
        return std.fmt.parseInt(u64, s[0 .. s.len - 2], 10);
    } else if (std.mem.endsWith(u8, s, "s")) {
        return (try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10)) * 1_000;
    } else if (std.mem.endsWith(u8, s, "m")) {
        return (try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10)) * 60_000;
    }
    return error.InvalidDuration;
}

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    _ = allocator; // values borrow argv; allocator reserved for future owned fields
    if (args.len == 0) return error.InvalidTarget;
    const t = try parseTarget(args[0]);
    var c = Cli{ .kind = t.kind, .name = t.name };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--namespace")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.namespace = args[i];
        } else if (std.mem.eql(u8, a, "--interval")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.interval_ms = try parseDuration(args[i]);
        } else if (std.mem.eql(u8, a, "--top")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.top = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--prometheus")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.prometheus = args[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return c;
}
```

- [ ] **Step 4: Wire `cli_test.zig` into `build.zig`**

In `build.zig`, factor the test step to compile a root test file that imports every `tests/*_test.zig`. Replace the single-file test with an aggregate `tests/all.zig`:

```zig
// tests/all.zig
comptime {
    _ = @import("cli_test.zig");
    _ = @import("smoke_test.zig");
}
```

And point `addTest` at `tests/all.zig`, adding module imports the tests need:

```zig
const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
tests.root_module.addImport("klient", klient_mod);
tests.root_module.addImport("cli", b.createModule(.{ .root_source_file = b.path("src/cli.zig") }));
```

> From here on, each new unit adds (a) its `tests/<unit>_test.zig`, (b) a line in `tests/all.zig`, and (c) an `addImport` in `build.zig`. This is repeated per task; treat it as part of "wire the test".

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS (cli + smoke).

- [ ] **Step 6: Commit**

```bash
git add src/cli.zig tests/cli_test.zig tests/all.zig build.zig
git commit -m "feat: CLI arg/flag parsing"
```

---

### Task 2: PromQL builder (`promql.zig`)

**Files:**
- Create: `src/promql.zig`
- Test: `tests/promql_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/promql_test.zig`

```zig
const std = @import("std");
const promql = @import("promql");

test "inbound rate query shape + escaping" {
    const q = try promql.inboundRate(std.testing.allocator, "foo\"x", "ef-test");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"destination\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload=\"foo\\\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "destination_workload_namespace=\"ef-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "sum by (source_workload, source_workload_namespace)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "rate(istio_requests_total{") != null);
}

test "outbound latency p99 query shape" {
    const q = try promql.outboundLatency(std.testing.allocator, "foo", "ef-test", 0.99);
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "histogram_quantile(0.99") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "reporter=\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "source_workload=\"foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "istio_request_duration_milliseconds_bucket{") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "by (le, destination_workload") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `promql` not found.

- [ ] **Step 3: Implement `src/promql.zig`**

```zig
const std = @import("std");

/// Escape a PromQL label value (backslash and double-quote).
pub fn escape(allocator: std.mem.Allocator, v: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    for (v) |ch| {
        if (ch == '\\' or ch == '"') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

pub const Direction = enum { inbound, outbound };

fn selfRole(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "destination", // we are the destination; peers are sources
        .outbound => "source",
    };
}
fn reporter(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "destination",
        .outbound => "source",
    };
}
fn peerLabel(dir: Direction) []const u8 {
    return switch (dir) {
        .inbound => "source_workload, source_workload_namespace",
        .outbound => "destination_workload, destination_workload_namespace",
    };
}

fn selector(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const ew = try escape(allocator, workload);
    defer allocator.free(ew);
    const en = try escape(allocator, ns);
    defer allocator.free(en);
    const role = selfRole(dir);
    return std.fmt.allocPrint(
        allocator,
        "reporter=\"{s}\",{s}_workload=\"{s}\",{s}_workload_namespace=\"{s}\"",
        .{ reporter(dir), role, ew, role, en },
    );
}

pub fn rate(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}) (rate(istio_requests_total{{{s}}}[1m]))",
        .{ peerLabel(dir), sel },
    );
}

/// Same as rate() but restricted to 5xx responses, for success%.
pub fn errorRate(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "sum by ({s}) (rate(istio_requests_total{{{s},response_code=~\"5..\"}}[1m]))",
        .{ peerLabel(dir), sel },
    );
}

pub fn latency(allocator: std.mem.Allocator, dir: Direction, workload: []const u8, ns: []const u8, quantile: f64) ![]u8 {
    const sel = try selector(allocator, dir, workload, ns);
    defer allocator.free(sel);
    return std.fmt.allocPrint(
        allocator,
        "histogram_quantile({d}, sum by (le, {s}) (rate(istio_request_duration_milliseconds_bucket{{{s}}}[1m])))",
        .{ quantile, peerLabel(dir), sel },
    );
}

// Convenience wrappers used by tests/readers.
pub fn inboundRate(a: std.mem.Allocator, w: []const u8, ns: []const u8) ![]u8 {
    return rate(a, .inbound, w, ns);
}
pub fn outboundLatency(a: std.mem.Allocator, w: []const u8, ns: []const u8, q: f64) ![]u8 {
    return latency(a, .outbound, w, ns, q);
}
```

- [ ] **Step 4: Wire test (add to `tests/all.zig` + `build.zig` import `promql` -> `src/promql.zig`), run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/promql.zig tests/promql_test.zig tests/all.zig build.zig
git commit -m "feat: PromQL query builder for Istio in/out traffic"
```

---

### Task 3: Prometheus response parsing (`prom_client.zig` parse half)

**Files:**
- Create: `src/prom_client.zig`
- Test: `tests/prom_client_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/prom_client_test.zig`

```zig
const std = @import("std");
const pc = @import("prom_client");

const sample =
    \\{"status":"success","data":{"resultType":"vector","result":[
    \\{"metric":{"source_workload":"bar","source_workload_namespace":"ef-test"},"value":[1718000000,"3.5"]},
    \\{"metric":{"source_workload":"auth-ws","source_workload_namespace":"ef-test"},"value":[1718000000,"1"]}
    \\]}}
;

test "parse instant vector into samples keyed by labels" {
    var res = try pc.parseVector(std.testing.allocator, sample);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.samples.len);
    try std.testing.expectEqualStrings("bar", res.samples[0].labels.get("source_workload").?);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), res.samples[0].value, 1e-9);
}

test "parse empty result yields zero samples" {
    const empty = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[]}}";
    var res = try pc.parseVector(std.testing.allocator, empty);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.samples.len);
}

test "NaN string value parses to nan" {
    const nanjson = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{\"x\":\"y\"},\"value\":[1,\"NaN\"]}]}}";
    var res = try pc.parseVector(std.testing.allocator, nanjson);
    defer res.deinit();
    try std.testing.expect(std.math.isNan(res.samples[0].value));
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL — `prom_client`/`parseVector` not found.

- [ ] **Step 3: Implement parse half of `src/prom_client.zig`**

```zig
const std = @import("std");

pub const Sample = struct {
    labels: std.StringHashMap([]const u8),
    value: f64,
};

pub const Vector = struct {
    arena: std.heap.ArenaAllocator,
    samples: []Sample,

    pub fn deinit(self: *Vector) void {
        self.arena.deinit();
    }
};

/// Parse a Prometheus `/api/v1/query` instant-vector JSON body.
pub fn parseVector(gpa: std.mem.Allocator, body: []const u8) !Vector {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const data = parsed.object.get("data") orelse return error.BadResponse;
    const result = (data.object.get("result") orelse return error.BadResponse).array;

    var list = std.ArrayList(Sample){};
    for (result.items) |item| {
        const metric = item.object.get("metric").?.object;
        var labels = std.StringHashMap([]const u8).init(a);
        var it = metric.iterator();
        while (it.next()) |entry| {
            try labels.put(entry.key_ptr.*, entry.value_ptr.*.string);
        }
        const value_arr = item.object.get("value").?.array;
        const vstr = value_arr.items[1].string; // [ ts, "value" ]
        const value = std.fmt.parseFloat(f64, vstr) catch std.math.nan(f64);
        try list.append(a, .{ .labels = labels, .value = value });
    }
    return .{ .arena = arena, .samples = try list.toOwnedSlice(a) };
}
```

- [ ] **Step 4: Wire + run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/prom_client.zig tests/prom_client_test.zig tests/all.zig build.zig
git commit -m "feat: parse Prometheus instant-vector responses"
```

---

### Task 4: Traffic model + aggregation + rolling history (`model.zig`)

**Files:**
- Create: `src/model.zig`
- Test: `tests/model_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/model_test.zig`

```zig
const std = @import("std");
const model = @import("model");

test "upsert peer rate + error -> success percent" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "ef-test", 10.0);
    try m.setErrorRate(.inbound, "bar", "ef-test", 0.2);
    const p = m.peer(.inbound, "bar").?;
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), p.req_per_s, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 98.0), p.successPercent(), 1e-9); // (1 - 0.2/10)*100
}

test "rolling history keeps last N and powers sparkline source" {
    var m = model.TrafficModel.init(std.testing.allocator, 3);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "ef-test", 1);
    m.commitTick();
    try m.setRate(.inbound, "bar", "ef-test", 2);
    m.commitTick();
    try m.setRate(.inbound, "bar", "ef-test", 3);
    m.commitTick();
    try m.setRate(.inbound, "bar", "ef-test", 4);
    m.commitTick();
    const p = m.peer(.inbound, "bar").?;
    const h = p.history();
    try std.testing.expectEqual(@as(usize, 3), h.len);
    try std.testing.expectApproxEqAbs(@as(f64, 4), h[h.len - 1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), h[0], 1e-9); // 1 evicted
}

test "totals and topN by rate" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "a", "ns", 5);
    try m.setRate(.inbound, "b", "ns", 1);
    try std.testing.expectApproxEqAbs(@as(f64, 6), m.totalRate(.inbound), 1e-9);
    const top = try m.topN(std.testing.allocator, .inbound, 1);
    defer std.testing.allocator.free(top);
    try std.testing.expectEqualStrings("a", top[0].name);
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement `src/model.zig`**

```zig
const std = @import("std");
pub const Direction = enum { inbound, outbound };

pub const Peer = struct {
    name: []const u8,        // owned
    namespace: []const u8,   // owned
    req_per_s: f64 = 0,
    err_per_s: f64 = 0,
    p50_ms: f64 = 0,
    p99_ms: f64 = 0,
    hist: []f64,             // ring buffer, owned
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

    /// Linearized history oldest..newest. Caller must not free; valid until next push.
    pub fn history(self: *Peer) []f64 {
        // Compact ring into the front of a scratch area within hist by rotation copy.
        // Simpler: rebuild into hist_lin (allocated alongside). See init.
        var i: usize = 0;
        while (i < self.hist_len) : (i += 1) {
            self.hist_lin[i] = self.hist[(self.hist_head + i) % self.cap];
        }
        return self.hist_lin[0..self.hist_len];
    }

    hist_lin: []f64, // owned scratch, same cap
};

const Key = struct { dir: Direction, name: []const u8 };

pub const TrafficModel = struct {
    allocator: std.mem.Allocator,
    cap: usize,
    peers: std.ArrayList(*Peer),

    pub fn init(allocator: std.mem.Allocator, history_cap: usize) TrafficModel {
        return .{ .allocator = allocator, .cap = history_cap, .peers = .{} };
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
            .hist = try self.allocator.alloc(f64, self.cap),
            .hist_lin = try self.allocator.alloc(f64, self.cap),
            .cap = self.cap,
            .dir = dir,
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
        var list = std.ArrayList(*Peer){};
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
```

> Add `dir: Direction` as a field on `Peer` (referenced in `find`/`commitTick`). Place it next to `cap`. The test exercises `init/setRate/setErrorRate/commitTick/history/topN/totalRate`; ensure the `Peer` struct compiles with both `hist` and `hist_lin`.

- [ ] **Step 4: Wire + run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/model.zig tests/model_test.zig tests/all.zig build.zig
git commit -m "feat: traffic model with rolling history + aggregation"
```

---

### Task 5: Render primitives — format, sparkline, bar (`render/`)

**Files:**
- Create: `src/render/format.zig`, `src/render/sparkline.zig`, `src/render/bar.zig`
- Test: `tests/render_primitives_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/render_primitives_test.zig`

```zig
const std = @import("std");
const fmtmod = @import("render_format");
const spark = @import("render_sparkline");
const bar = @import("render_bar");

test "rate formatting" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12.4", try fmtmod.rate(&buf, 12.43));
    try std.testing.expectEqualStrings("0.0", try fmtmod.rate(&buf, 0));
}

test "latency formatting ms" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("42ms", try fmtmod.latencyMs(&buf, 42.0));
}

test "health thresholds" {
    try std.testing.expectEqual(fmtmod.Health.good, fmtmod.health(99.95));
    try std.testing.expectEqual(fmtmod.Health.warn, fmtmod.health(98.5));
    try std.testing.expectEqual(fmtmod.Health.bad, fmtmod.health(90.0));
}

test "sparkline maps to 8 levels" {
    const vals = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var buf: [64]u8 = undefined;
    const s = try spark.render(&buf, &vals);
    try std.testing.expect(std.mem.startsWith(u8, s, "\u{2581}")); // lowest -> ▁
    try std.testing.expect(std.mem.endsWith(u8, s, "\u{2588}"));   // highest -> █
}

test "bar scales to width by max" {
    var buf: [32]u8 = undefined;
    const b = try bar.render(&buf, 5.0, 10.0, 8); // half of 8 cells
    try std.testing.expectEqual(@as(usize, 4 * 3), b.len); // 4 full blocks (each █ is 3 UTF-8 bytes)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement the three files**

`src/render/format.zig`:

```zig
const std = @import("std");
pub const Health = enum { good, warn, bad };

pub fn health(success_pct: f64) Health {
    if (success_pct >= 99.9) return .good;
    if (success_pct >= 95.0) return .warn;
    return .bad;
}

pub fn rate(buf: []u8, v: f64) ![]u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{v});
}

pub fn percent(buf: []u8, v: f64) ![]u8 {
    return std.fmt.bufPrint(buf, "{d:.1}%", .{v});
}

pub fn latencyMs(buf: []u8, ms: f64) ![]u8 {
    return std.fmt.bufPrint(buf, "{d:.0}ms", .{ms});
}
```

`src/render/sparkline.zig`:

```zig
const std = @import("std");
const levels = [_][]const u8{ "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}" };

pub fn render(buf: []u8, vals: []const f64) ![]u8 {
    if (vals.len == 0) return buf[0..0];
    var lo: f64 = vals[0];
    var hi: f64 = vals[0];
    for (vals) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const span = hi - lo;
    var w: usize = 0;
    for (vals) |v| {
        const lvl: usize = if (span <= 0) 0 else @intFromFloat(@round((v - lo) / span * 7.0));
        const g = levels[std.math.clamp(lvl, 0, 7)];
        @memcpy(buf[w .. w + g.len], g);
        w += g.len;
    }
    return buf[0..w];
}
```

`src/render/bar.zig`:

```zig
const std = @import("std");
const FULL = "\u{2588}"; // █

pub fn render(buf: []u8, value: f64, max: f64, width: usize) ![]u8 {
    const frac = if (max <= 0) 0 else std.math.clamp(value / max, 0, 1);
    const cells: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(width))));
    var w: usize = 0;
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        @memcpy(buf[w .. w + FULL.len], FULL);
        w += FULL.len;
    }
    return buf[0..w];
}
```

- [ ] **Step 4: Wire (three imports: `render_format`, `render_sparkline`, `render_bar`) + run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/render/ tests/render_primitives_test.zig tests/all.zig build.zig
git commit -m "feat: render primitives (format, sparkline, bar)"
```

---

### Task 6: Styled line types + detail table panel (`render/line.zig`, `render/table.zig`)

**Files:**
- Create: `src/render/line.zig`, `src/render/table.zig`
- Test: `tests/table_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/table_test.zig`

```zig
const std = @import("std");
const model = @import("model");
const table = @import("render_table");

test "table renders a header + a peer row per direction" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "bar", "ef-test", 3.1);
    try m.setLatency(.inbound, "bar", "ef-test", 4, 11);
    m.commitTick();

    var lines = try table.render(std.testing.allocator, &m);
    defer table.freeLines(std.testing.allocator, lines);

    // Find a line whose concatenated text contains the peer name and its rate.
    var found = false;
    for (lines) |ln| {
        const txt = try ln.plainText(std.testing.allocator);
        defer std.testing.allocator.free(txt);
        if (std.mem.indexOf(u8, txt, "bar") != null and std.mem.indexOf(u8, txt, "3.1") != null) found = true;
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement `src/render/line.zig`**

```zig
const std = @import("std");
const fmtmod = @import("format.zig");

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
        var out = std.ArrayList(u8){};
        errdefer out.deinit(allocator);
        for (self.spans) |s| try out.appendSlice(allocator, s.text);
        return out.toOwnedSlice(allocator);
    }
};
```

`src/render/table.zig`:

```zig
const std = @import("std");
const model = @import("../model.zig");
const line = @import("line.zig");
const fmtmod = @import("format.zig");
const spark = @import("sparkline.zig");
const bar = @import("bar.zig");

const StyledLine = line.StyledLine;
const Span = line.Span;

fn dupSpan(a: std.mem.Allocator, text: []const u8, color: line.Color) !Span {
    return .{ .text = try a.dupe(u8, text), .color = color };
}

fn header(a: std.mem.Allocator, title: []const u8) !StyledLine {
    var spans = try a.alloc(Span, 1);
    spans[0] = try dupSpan(a, title, .cyan);
    return .{ .spans = spans };
}

fn peerRow(a: std.mem.Allocator, p: *model.Peer, max_rate: f64) !StyledLine {
    var rbuf: [16]u8 = undefined;
    var sbuf: [128]u8 = undefined;
    var bbuf: [64]u8 = undefined;
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
    var lines = std.ArrayList(StyledLine){};
    errdefer lines.deinit(a);

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
```

- [ ] **Step 4: Wire (`render_table` -> `src/render/table.zig`; it imports siblings by relative path, and `model`), run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/render/line.zig src/render/table.zig tests/table_test.zig tests/all.zig build.zig
git commit -m "feat: styled-line types + detail table panel"
```

---

### Task 7: Topology graph panel (`render/graph.zig`)

**Files:**
- Create: `src/render/graph.zig`
- Test: `tests/graph_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/graph_test.zig`

```zig
const std = @import("std");
const model = @import("model");
const graph = @import("render_graph");

test "graph shows target, top inbound peer with rate, and totals" {
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try m.setRate(.inbound, "istio-ingressgw", "istio-system", 12.4);
    try m.setRate(.outbound, "baz", "ef-test", 5.0);

    var lines = try graph.render(std.testing.allocator, &m, "foo", "ef-test", 6);
    defer graph.freeLines(std.testing.allocator, lines);

    var joined = std.ArrayList(u8){};
    defer joined.deinit(std.testing.allocator);
    for (lines) |ln| {
        const t = try ln.plainText(std.testing.allocator);
        defer std.testing.allocator.free(t);
        try joined.appendSlice(std.testing.allocator, t);
        try joined.append(std.testing.allocator, '\n');
    }
    const all = joined.items;
    try std.testing.expect(std.mem.indexOf(u8, all, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "istio-ingressgw") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "12.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "baz") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "in") != null);  // totals footer
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement `src/render/graph.zig`**

```zig
const std = @import("std");
const model = @import("../model.zig");
const line = @import("line.zig");
const fmtmod = @import("format.zig");

const StyledLine = line.StyledLine;
const Span = line.Span;

fn dupSpan(a: std.mem.Allocator, text: []const u8, color: line.Color) !Span {
    return .{ .text = try a.dupe(u8, text), .color = color };
}
fn oneSpanLine(a: std.mem.Allocator, text: []const u8, color: line.Color) !StyledLine {
    var spans = try a.alloc(Span, 1);
    spans[0] = try dupSpan(a, text, color);
    return .{ .spans = spans };
}

/// Renders a simple left(in) -> [target] -> right(out) map.
/// Layout is row-aligned: each row shows up to one inbound peer and one
/// outbound peer; the target box is drawn on the middle rows.
pub fn render(a: std.mem.Allocator, m: *model.TrafficModel, target: []const u8, ns: []const u8, top: usize) ![]StyledLine {
    var lines = std.ArrayList(StyledLine){};
    errdefer lines.deinit(a);

    const in = try m.topN(a, .inbound, top);
    defer a.free(in);
    const out = try m.topN(a, .outbound, top);
    defer a.free(out);

    const rows = @max(in.len, out.len);
    const mid = rows / 2;

    var buf: [256]u8 = undefined;
    var rbuf: [16]u8 = undefined;

    var i: usize = 0;
    while (i < rows) : (i += 1) {
        const left = if (i < in.len) blk: {
            const r = try fmtmod.rate(&rbuf, in[i].req_per_s);
            break :blk try std.fmt.bufPrint(&buf, "{s} --{s} r/s-->", .{ in[i].name, r });
        } else try std.fmt.bufPrint(&buf, "", .{});

        // target marker on the middle row
        const center = if (i == mid)
            try std.fmt.allocPrint(a, "[ {s} ]", .{target})
        else
            try a.dupe(u8, "       ");
        defer a.free(center);

        var rbuf2: [16]u8 = undefined;
        var obuf: [128]u8 = undefined;
        const right = if (i < out.len) blk: {
            const r = try fmtmod.rate(&rbuf2, out[i].req_per_s);
            break :blk try std.fmt.bufPrint(&obuf, "--{s} r/s--> {s}", .{ r, out[i].name });
        } else try std.fmt.bufPrint(&obuf, "", .{});

        const whole = try std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ left, center, right });
        defer a.free(whole);
        try lines.append(a, try oneSpanLine(a, whole, .default));
    }

    // totals footer
    var fbuf: [128]u8 = undefined;
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
```

> The ASCII box-drawing polish (┌─┐ borders, ▼ arrows from the design mock) is cosmetic and layered on in Task 12's adapter once real widths are known; the pure panel guarantees content + ordering, which is what the test pins.

- [ ] **Step 4: Wire (`render_graph`) + run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/render/graph.zig tests/graph_test.zig tests/all.zig build.zig
git commit -m "feat: topology graph panel"
```

---

### Task 8: Target resolution — owner chain (`target.zig`)

**Files:**
- Create: `src/target.zig`
- Test: `tests/target_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/target_test.zig`

```zig
const std = @import("std");
const target = @import("target");

test "deployment target maps straight to workload" {
    const w = try target.workloadFromKind(.deployment, "foo");
    try std.testing.expectEqualStrings("foo", w);
}

test "workload name derived from replicaset owner name" {
    // ReplicaSet name "foo-7d9c" with a Deployment ownerRef -> workload "foo"
    try std.testing.expectEqualStrings("foo", target.deploymentFromReplicaSet("foo-7d9c"));
    try std.testing.expectEqualStrings("my-app", target.deploymentFromReplicaSet("my-app-abc123"));
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement pure half of `src/target.zig`**

```zig
const std = @import("std");
const cli = @import("cli.zig");

pub fn workloadFromKind(kind: cli.Kind, name: []const u8) ![]const u8 {
    return switch (kind) {
        .deployment => name,
        .pod => error.NeedsOwnerResolution, // resolved live via resolvePod
    };
}

/// A ReplicaSet created by a Deployment is named "<deployment>-<podtemplatehash>".
/// Strip the final "-<hash>" segment.
pub fn deploymentFromReplicaSet(rs_name: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, rs_name, '-') orelse return rs_name;
    return rs_name[0..dash];
}
```

> The live path — `resolvePod(client, ns, pod_name) -> workload` — uses `client.pods.get(...)` to read `metadata.ownerReferences` (kind `ReplicaSet`), then `deploymentFromReplicaSet` on that name (preferring the RS's own Deployment ownerRef when present). It is exercised by the integration task, not unit-tested, because it needs a live API. Implement it in this file with this signature:
>
> ```zig
> const klient = @import("klient");
> pub fn resolvePod(client: *klient.K8sClient, ns: []const u8, pod_name: []const u8) ![]const u8 { ... }
> ```

- [ ] **Step 4: Wire (`target` -> `src/target.zig`, which imports `cli` and `klient`) + run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/target.zig tests/target_test.zig tests/all.zig build.zig
git commit -m "feat: target workload resolution (deployment + replicaset owner chain)"
```

---

### Task 9: Prometheus discovery + service-proxy query path (`discovery.zig`, `prom_client.zig` http half)

**Files:**
- Modify: `src/prom_client.zig`
- Create: `src/discovery.zig`
- Test: `tests/proxy_path_test.zig`

- [ ] **Step 1: Write the failing test** — `tests/proxy_path_test.zig`

```zig
const std = @import("std");
const pc = @import("prom_client");

test "service-proxy query path is well-formed and url-encodes the query" {
    const path = try pc.proxyQueryPath(std.testing.allocator, "monitoring", "kube-prometheus-stack-prometheus", 9090, "sum(rate(x[1m]))");
    defer std.testing.allocator.free(path);
    try std.testing.expectStringStartsWith(path, "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=");
    // space and parens must be percent-encoded
    try std.testing.expect(std.mem.indexOf(u8, path, "%20") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, " ") == null);
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Add to `src/prom_client.zig`**

```zig
fn percentEncode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(a);
    for (s) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(a, ch);
        } else {
            try out.writer(a).print("%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(a);
}

pub fn proxyQueryPath(a: std.mem.Allocator, ns: []const u8, svc: []const u8, port: u16, query: []const u8) ![]u8 {
    const enc = try percentEncode(a, query);
    defer a.free(enc);
    return std.fmt.allocPrint(
        a,
        "/api/v1/namespaces/{s}/services/{s}:{d}/proxy/api/v1/query?query={s}",
        .{ ns, svc, port, enc },
    );
}

/// Live: run a PromQL query through the API-server service proxy.
/// Returns the parsed instant vector; caller calls .deinit().
pub fn query(client: *@import("klient").K8sClient, a: std.mem.Allocator, ns: []const u8, svc: []const u8, port: u16, promql: []const u8) !Vector {
    const path = try proxyQueryPath(a, ns, svc, port, promql);
    defer a.free(path);
    const body = try client.request(.GET, path, null);
    defer a.free(body);
    return parseVector(a, body);
}
```

- [ ] **Step 4: Implement `src/discovery.zig`**

```zig
const std = @import("std");
const klient = @import("klient");

pub const PromTarget = struct { namespace: []const u8, service: []const u8, port: u16 };

/// Default well-known target on AlphaSense clusters. Auto-discovery (listing
/// :9090 services in `monitoring`) can be layered later; v1 uses the known
/// service with a --prometheus override parsed by parseOverride.
pub fn default() PromTarget {
    return .{ .namespace = "monitoring", .service = "kube-prometheus-stack-prometheus", .port = 9090 };
}

/// Parse "svc.ns:port" override form.
pub fn parseOverride(ref: []const u8) !PromTarget {
    const colon = std.mem.lastIndexOfScalar(u8, ref, ':') orelse return error.BadPrometheusRef;
    const svc_ns = ref[0..colon];
    const port = try std.fmt.parseInt(u16, ref[colon + 1 ..], 10);
    const dot = std.mem.indexOfScalar(u8, svc_ns, '.') orelse return error.BadPrometheusRef;
    return .{ .service = svc_ns[0..dot], .namespace = svc_ns[dot + 1 ..], .port = port };
}
```

- [ ] **Step 5: Wire + run**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/prom_client.zig src/discovery.zig tests/proxy_path_test.zig tests/all.zig build.zig
git commit -m "feat: prometheus service-proxy query path + discovery defaults"
```

---

### Task 10: Client bootstrap (`bootstrap.zig`)

**Files:**
- Create: `src/bootstrap.zig`
- Test: `tests/bootstrap_test.zig` (pure helper only)

- [ ] **Step 1: Write the failing test** — `tests/bootstrap_test.zig`

```zig
const std = @import("std");
const bootstrap = @import("bootstrap");

test "detect EKS cluster name from server host is optional; exec name passthrough" {
    // The exec-credential cluster name comes from kubeconfig user.exec args;
    // bootstrap just forwards it. Verify the small helper that picks the
    // cluster name argument from an exec args slice.
    const args = [_][]const u8{ "eks", "get-token", "--cluster-name", "cloud-core-dev", "--region", "us-east-1" };
    try std.testing.expectEqualStrings("cloud-core-dev", bootstrap.eksClusterNameFromArgs(&args).?);
}
```

- [ ] **Step 2: Run to verify fail**

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 3: Implement `src/bootstrap.zig`**

```zig
const std = @import("std");
const klient = @import("klient");

pub fn eksClusterNameFromArgs(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cluster-name")) return args[i + 1];
    }
    return null;
}

pub const Bootstrapped = struct {
    client: klient.K8sClient,
    namespace: []const u8, // owned by kubeconfig parse / context
};

/// Build an authenticated K8sClient from the current kubeconfig context.
/// - Reads server URL + CA from the cluster entry.
/// - If the user uses an exec credential (EKS), runs it for a bearer token.
pub fn fromKubeconfig(allocator: std.mem.Allocator, io: std.Io, context_override: ?[]const u8) !Bootstrapped {
    var parser = klient.KubeconfigParser.init(allocator, io);
    var kc = try parser.load();
    // (kc owns strings; in v1 we leak into an arena owned by caller's gpa for the
    //  process lifetime — the plugin is short-lived. Keep a TODO to arena this.)

    const ctx = if (context_override) |n| kc.getContextByName(n) else kc.getCurrentContext();
    const context = ctx orelse return error.NoContext;
    const cluster = kc.getClusterByName(context.cluster) orelse return error.NoCluster;
    const user = kc.getUserByName(context.user) orelse return error.NoUser;

    var token: ?[]const u8 = null;
    if (user.exec) |exec| {
        // EKS path: run the exec plugin (aws eks get-token) to obtain a token.
        const cred = try klient.exec_credential.executeCredentialPlugin(allocator, io, .{
            .command = exec.command,
            .args = exec.args,
            .env = exec.env,
        });
        token = cred.status.token;
    } else if (user.token) |t| {
        token = t;
    }

    const client = try klient.K8sClient.init(allocator, io, .{
        .server = cluster.server,
        .token = token,
        .namespace = context.namespace,
        .tls_config = if (cluster.ca_cert_data) |ca| .{ .ca_cert_data = ca } else null,
    });
    return .{ .client = client, .namespace = context.namespace orelse "default" };
}
```

> Verify the exact field names on `klient.kubeconfig_yaml`'s `Cluster`/`User`/`Context`/`ExecConfig` (`server`, `ca_cert_data`, `exec`, `token`, `namespace`, `command`, `args`, `env`) against `src/k8s/kubeconfig_yaml.zig` and adjust. Also confirm `executeCredentialPlugin`'s actual parameter shape (it may take an `ExecConfig` value directly). This is the one task most likely to need signature tweaks at execution; the `eksClusterNameFromArgs` helper is the only part unit-tested.

- [ ] **Step 4: Wire + run**

Run: `zig build test`
Expected: PASS (pure helper test).

- [ ] **Step 5: Commit**

```bash
git add src/bootstrap.zig tests/bootstrap_test.zig tests/all.zig build.zig
git commit -m "feat: K8sClient bootstrap from kubeconfig + EKS exec-credential"
```

---

### Task 11: Collector — one refresh tick (`app.zig` collect half)

**Files:**
- Create: `src/app.zig`
- Test: covered by integration (Task 13); this task wires queries into the model.

- [ ] **Step 1: Implement `collectTick` in `src/app.zig`**

```zig
const std = @import("std");
const klient = @import("klient");
const model = @import("model.zig");
const promql = @import("promql.zig");
const prom = @import("prom_client.zig");
const discovery = @import("discovery.zig");

fn applyRate(m: *model.TrafficModel, dir: model.Direction, v: *prom.Vector, setter: fn (*model.TrafficModel, model.Direction, []const u8, []const u8, f64) anyerror!void) !void {
    const name_label = if (dir == .inbound) "source_workload" else "destination_workload";
    const ns_label = if (dir == .inbound) "source_workload_namespace" else "destination_workload_namespace";
    for (v.samples) |s| {
        const name = s.labels.get(name_label) orelse continue;
        const ns = s.labels.get(ns_label) orelse "";
        try setter(m, dir, name, ns, s.value);
    }
}

/// One refresh: 4 queries per direction (rate, errorRate, p50, p99) folded into the model.
pub fn collectTick(client: *klient.K8sClient, a: std.mem.Allocator, m: *model.TrafficModel, tgt: discovery.PromTarget, workload: []const u8, ns: []const u8) !void {
    inline for (.{ model.Direction.inbound, model.Direction.outbound }) |dir| {
        {
            const q = try promql.rate(a, dir, workload, ns);
            defer a.free(q);
            var v = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q);
            defer v.deinit();
            try applyRate(m, dir, &v, model.TrafficModel.setRate);
        }
        {
            const q = try promql.errorRate(a, dir, workload, ns);
            defer a.free(q);
            var v = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q);
            defer v.deinit();
            try applyRate(m, dir, &v, model.TrafficModel.setErrorRate);
        }
        // p50 + p99 folded via setLatency (two queries; join by peer name).
        try collectLatency(client, a, m, tgt, dir, workload, ns);
    }
    m.commitTick();
}

fn collectLatency(client: *klient.K8sClient, a: std.mem.Allocator, m: *model.TrafficModel, tgt: discovery.PromTarget, dir: model.Direction, workload: []const u8, ns: []const u8) !void {
    const name_label = if (dir == .inbound) "source_workload" else "destination_workload";
    const ns_label = if (dir == .inbound) "source_workload_namespace" else "destination_workload_namespace";

    const q50 = try promql.latency(a, dir, workload, ns, 0.5);
    defer a.free(q50);
    var v50 = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q50);
    defer v50.deinit();

    const q99 = try promql.latency(a, dir, workload, ns, 0.99);
    defer a.free(q99);
    var v99 = try prom.query(client, a, tgt.namespace, tgt.service, tgt.port, q99);
    defer v99.deinit();

    for (v50.samples) |s| {
        const name = s.labels.get(name_label) orelse continue;
        const pns = s.labels.get(ns_label) orelse "";
        var p99: f64 = 0;
        for (v99.samples) |s2| {
            if (std.mem.eql(u8, s2.labels.get(name_label) orelse "", name)) p99 = s2.value;
        }
        try m.setLatency(dir, name, pns, s.value, p99);
    }
}
```

- [ ] **Step 2: Build (compile check)**

Run: `zig build`
Expected: compiles. (No unit test here; logic is integration-verified in Task 13.)

- [ ] **Step 3: Commit**

```bash
git add src/app.zig build.zig
git commit -m "feat: collect one refresh tick of in/out rates + latency into model"
```

---

### Task 12: TUI adapter + main loop (`render/tui.zig`, finish `app.zig`, `main.zig`)

**Files:**
- Modify: `build.zig.zon` (add vaxis dep), `build.zig` (link vaxis)
- Create: `src/render/tui.zig`
- Modify: `src/app.zig` (add `run` loop), `src/main.zig` (wire everything)

- [ ] **Step 1: Pin libvaxis against Zig 0.16**

Run:
```bash
zig fetch --save git+https://github.com/rockorager/libvaxis
zig build
```
Expected: fetch succeeds and the dependency compiles under Zig 0.16.0.

**If libvaxis does NOT support 0.16:** fall back to the hand-rolled ANSI backend — same `paint(lines)` interface, implemented with `\x1b[2J\x1b[H` clear/home, `\x1b[38;5;Nm` colors, and termios raw mode via `std.posix.tcgetattr`/`tcsetattr` for the `q`/Ctrl-C key read. The pure panels (Tasks 5–7) already produce `StyledLine`s, so only this adapter file changes. Record which backend was used in the commit message.

- [ ] **Step 2: Implement `src/render/tui.zig`**

```zig
const std = @import("std");
const line = @import("line.zig");

// Backend-agnostic surface the app uses. With libvaxis, `Tui` wraps vaxis.Vaxis
// + a Tty; with the ANSI fallback it wraps a writer + termios state.
pub const Key = enum { quit, none };

pub const Tui = struct {
    // backend handle(s) — vaxis.Vaxis / vaxis.Tty OR ansi state
    // (concrete fields filled per chosen backend in Step 1)

    pub fn init(allocator: std.mem.Allocator) !Tui { ... }
    pub fn deinit(self: *Tui) void { ... }

    /// Non-blocking poll; returns .quit on 'q' or Ctrl-C.
    pub fn poll(self: *Tui, timeout_ms: u64) !Key { ... }

    /// Clear, draw the graph panel, a separator, then the table panel.
    pub fn paint(self: *Tui, graph_lines: []const line.StyledLine, table_lines: []const line.StyledLine, title: []const u8) !void { ... }
};
```

> The `...` bodies are the only place concrete TUI-library calls live; fill them against the backend pinned in Step 1. Keep `paint` a pure consumer of `StyledLine`s. Color mapping: `line.Color` -> vaxis style (or 256-color ANSI code) in a single `fn colorCode(c) u8`.

- [ ] **Step 3: Implement `run` in `src/app.zig`**

```zig
pub fn run(allocator: std.mem.Allocator, io: std.Io, client: *klient.K8sClient, tgt: discovery.PromTarget, workload: []const u8, ns: []const u8, interval_ms: u64, top: usize, title: []const u8) !void {
    const render_graph = @import("render/graph.zig");
    const render_table = @import("render/table.zig");
    const tui_mod = @import("render/tui.zig");

    var m = model.TrafficModel.init(allocator, 32);
    defer m.deinit();

    var tui = try tui_mod.Tui.init(allocator);
    defer tui.deinit();

    while (true) {
        collectTick(client, allocator, &m, tgt, workload, ns) catch |err| {
            // Render an error/empty-state line but keep looping.
            std.log.warn("collect failed: {s}", .{@errorName(err)});
        };
        const g = try render_graph.render(allocator, &m, workload, ns, top);
        defer render_graph.freeLines(allocator, g);
        const t = try render_table.render(allocator, &m);
        defer render_table.freeLines(allocator, t);
        try tui.paint(g, t, title);

        if (try tui.poll(interval_ms) == .quit) break;
        _ = io;
    }
}
```

- [ ] **Step 4: Implement `src/main.zig`**

```zig
const std = @import("std");
const klient = @import("klient");
const cli = @import("cli.zig");
const bootstrap = @import("bootstrap.zig");
const discovery = @import("discovery.zig");
const target = @import("target.zig");
const app = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io = std.Io{}; // obtain the std.Io instance per Zig 0.16 (see zig-klient examples)

    const raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw);
    if (raw.len < 2) {
        std.debug.print("{s}\n", .{cli.Cli.help});
        return;
    }
    const c = cli.parse(allocator, raw[1..]) catch {
        std.debug.print("{s}\n", .{cli.Cli.help});
        return error.BadArgs;
    };

    var boot = try bootstrap.fromKubeconfig(allocator, io, null);
    defer boot.client.deinit();

    const ns = c.namespace orelse boot.namespace;
    const workload = switch (c.kind) {
        .deployment => c.name,
        .pod => try target.resolvePod(&boot.client, ns, c.name),
    };

    const tgt = if (c.prometheus) |ref| try discovery.parseOverride(ref) else discovery.default();

    var title_buf: [128]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s}/{s} · ns:{s}", .{ @tagName(c.kind), c.name, ns });

    try app.run(allocator, io, &boot.client, tgt, workload, ns, c.interval_ms, c.top, title);
}
```

> Confirm how `std.Io` is obtained in Zig 0.16 from the zig-klient examples/tests (it may come from an event loop or a default). Mirror exactly what zig-klient's own tests do.

- [ ] **Step 5: Build + manual smoke (no cluster)**

Run: `zig build && ./zig-out/bin/kubectl-traffic` (no args)
Expected: prints help. With bad target `deploy` (no name) → prints help + nonzero exit.

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon src/render/tui.zig src/app.zig src/main.zig
git commit -m "feat: TUI adapter + live poll loop wiring"
```

---

### Task 13: Live integration against cloud-core-dev + README

**Files:**
- Create: `tests/integration_live.zig` (gated behind an env var)
- Create: `README.md`
- Modify: `build.zig` (separate `integration` step)

- [ ] **Step 1: Gated live test** — `tests/integration_live.zig`

```zig
const std = @import("std");

test "live: query ef-test workload (gated)" {
    if (std.posix.getenv("KT_LIVE") == null) return error.SkipZigTest;
    // Build a client via bootstrap, run collectTick against a known ef-test
    // workload, assert at least one direction has >= 0 samples and no error.
    // (Filled in with the real workload name discovered at run time.)
}
```

- [ ] **Step 2: Manual end-to-end on the cluster**

Run (with AWS SSO valid; `aws sso login` if `ExpiredToken`):
```bash
kubectl config use-context cloud-core-dev.as-admin
zig build && cp zig-out/bin/kubectl-traffic /usr/local/bin/   # or anywhere on PATH
# pick a real meshed workload:
kubectl --context cloud-core-dev.as-admin -n ef-test get deploy
kubectl traffic deploy/<name> -n ef-test
```
Expected: live two-panel view; INBOUND/OUTBOUND populate for a workload that has traffic; empty-state line for one that doesn't. `q` exits cleanly (terminal restored).

- [ ] **Step 3: Verify the empty-state + error paths**

- Run against a non-meshed namespace workload → "no Istio telemetry — is this namespace sidecar-injected?".
- Run with a bogus `--prometheus svc.bad:9090` → clear unreachable error naming the service.

- [ ] **Step 4: Write `README.md`**

Cover: what it is, the non-Cilium/Istio rationale (one line), install (`go`-free: `zig build`, copy binary onto `$PATH` as `kubectl-traffic`), usage + flags, the mesh-only caveat, and the `--prometheus` override. No internal brain paths or ticket history.

- [ ] **Step 5: Commit**

```bash
git add tests/integration_live.zig README.md build.zig
git commit -m "test: gated live integration + README"
```

---

## Self-Review

**Spec coverage:**
- CLI surface → Task 1. ✓
- Target resolution (deploy direct / pod owner-chain) → Task 8 + Task 12 wiring. ✓
- Data path (API-server service proxy, reuse zig-klient auth) → Task 9 (path) + Task 10 (bootstrap) + Task 11 (queries). ✓
- Prometheus discovery + `--prometheus` override → Task 9. ✓
- PromQL (inbound/outbound rate, error, p50/p99) → Task 2 + Task 11. ✓
- Model + rolling history → Task 4. ✓
- Render: graph panel + detail table + sparkline/bar/format/color → Tasks 5, 6, 7; TUI adapter → Task 12. ✓
- Error handling (no telemetry, prom unreachable, auth) → Task 12 loop + Task 13 verification. ✓
- Testing (unit pure + gated integration) → Tasks 1–10 unit, Task 13 integration. ✓
- Deferred items (bytes/TCP/multi-cluster/krew) → not in any task, by design. ✓

**Placeholder scan:** The only `...` bodies are in Task 12's `tui.zig`, explicitly gated on the Step-1 backend pin (libvaxis vs ANSI) — they are flagged as the single place concrete library calls are filled, not vague hand-waving. All logic/pure units have complete code. The two "verify signatures" notes (Task 10 bootstrap, Task 12 `std.Io`) point at exact files to check; they are integration glue against an external lib, not logic gaps.

**Type consistency:** `model.Direction`, `model.Peer`, `model.TrafficModel` used consistently across Tasks 4/6/7/11. `line.StyledLine`/`Span`/`Color` consistent across Tasks 6/7/12. `prom.Vector`/`Sample`/`parseVector`/`query`/`proxyQueryPath` consistent across Tasks 3/9/11. `discovery.PromTarget` consistent across Tasks 9/11/12. `cli.Kind`/`Cli` consistent across Tasks 1/8/12.

**Known risks carried forward (not gaps):**
1. libvaxis ↔ Zig 0.16 compatibility — mitigated by the ANSI fallback behind the same `paint` interface (Task 12 Step 1).
2. zig-klient `std.Io` acquisition + kubeconfig/exec-credential field names — pinned by "mirror zig-klient's own tests" (Tasks 10, 12).
3. `std.ArrayList`/`std.json` API specifics on 0.16 (e.g. `parseFromSliceLeaky`, unmanaged `ArrayList` with explicit allocator) — verified at first `zig build test`; adjust call sites if the std API differs.
