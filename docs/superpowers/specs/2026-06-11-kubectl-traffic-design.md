# kubectl-traffic — Design

**Date:** 2026-06-11
**Status:** Approved (design); pending implementation plan

## Summary

`kubectl-traffic` is a standalone Zig binary that, when run against a single
Kubernetes workload (a pod or deployment), shows a **live, top-style view of
that workload's L7 traffic** — inbound (who calls it) and outbound (what it
calls) — as a topology graph plus a detailed table. It is the practical
"Hubble-like" answer for clusters that run an **Istio** service mesh but **no
Cilium** (e.g. AlphaSense `cloud-core-dev`, which uses the AWS VPC CNI).

Traffic numbers come from **Istio's Prometheus metrics**
(`istio_requests_total`, `istio_request_duration_milliseconds`), queried via
PromQL. The plugin only sees workloads that are in the mesh (sidecar-injected).

## Motivation

- `cloud-core-dev` runs the **AWS VPC CNI (`aws-node`) + kube-proxy** — **not
  Cilium** — so Hubble is unavailable.
- The cluster does run **Istio** (istiod, sidecars, `telemetry.istio.io`),
  **Kiali**, and **kube-prometheus-stack**. Istio's Envoy sidecars emit rich
  L7 metrics to Prometheus.
- Kiali gives a whole-cluster graph in a browser, but there is no fast,
  terminal-native, per-workload "what's my traffic right now" view. This plugin
  fills that gap and stays in the kubectl workflow.

## Non-goals (v1)

Explicitly deferred:
- Byte/throughput columns (`istio_request_bytes` / `istio_response_bytes`).
- TCP / non-HTTP metrics (`istio_tcp_*`).
- Multi-cluster / cross-cluster aggregation.
- krew packaging and distribution.
- Any L3/L4 all-pod flow view (would require an eBPF tool not installed on the
  cluster).

## CLI surface

```
kubectl traffic <pod|deploy|deployment>/<name> [flags]

Flags:
  -n, --namespace <ns>        target namespace (default: current context ns)
      --interval <dur>        refresh interval (default: 2s)
      --prometheus <ref>      override Prometheus location, form svc/<name>.<ns>:<port>
                              (default: auto-discover in `monitoring`)
      --top <n>               max peers drawn in the graph per direction (default: 6)
  -h, --help
```

- Invoked as a kubectl plugin: any executable named `kubectl-traffic` on
  `$PATH` is reachable as `kubectl traffic`.
- Context and default namespace come from kubeconfig via `zig-klient`.
- Live view; redraws every `--interval`; exits on `q` or Ctrl-C.

## Architecture

Built on **`zig-klient`** (sibling repo) for Kubernetes access and on
**libvaxis** for the TUI. Zig 0.16.0.

Units (each independently testable):

1. **CLI / config** — parse args + flags, resolve context + namespace from
   kubeconfig.
2. **Target resolver** — turn `pod/x` or `deploy/x` into an Istio *workload*
   identity `(workload_name, namespace)`.
3. **Prometheus client** — issue PromQL queries to Prometheus through the
   Kubernetes **API-server service proxy**, parse the JSON response.
4. **Query builder** — construct the inbound/outbound PromQL strings for a
   target workload (with label escaping).
5. **Model / aggregator** — fold query results into an in-memory model of
   peers (per direction: req/s, success %, p50/p99) and maintain a rolling
   history buffer per peer for sparklines.
6. **Renderer** — draw the two-panel TUI (graph panel + detail table) with
   libvaxis; handle resize and input.
7. **Main loop** — poll on `--interval`, update model, redraw, handle quit.

### Data path (connection & auth)

Reuse `zig-klient`'s authenticated client. It already handles:
- kubeconfig parsing (`kubeconfig_yaml.zig` / `kubeconfig_json.zig`),
- EKS `exec-credential` auth (`exec_credential.zig`) — covers AlphaSense AWS
  SSO,
- TLS with proxy fallback (`tls.zig`, `proxy_fallback.zig`).

Rather than managing a `port-forward` listener lifecycle, the plugin reaches
Prometheus through the **API-server service proxy** — a single authenticated
HTTPS call per query:

```
GET /api/v1/namespaces/<promNs>/services/<promSvc>:<port>/proxy/api/v1/query?query=<PromQL>
```

This reuses all of `zig-klient`'s auth/TLS and needs no local socket. If the
service proxy is blocked by RBAC, fall back to `zig-klient`'s `port_forward.zig`
(documented as a fallback, not the default).

**Prometheus discovery:** default to a service exposing port `9090` in the
`monitoring` namespace. On `cloud-core-dev` this is
`kube-prometheus-stack-prometheus:9090` (Kiali itself uses
`prometheus-operated.monitoring.svc:9090`). `--prometheus` overrides discovery.

### Target resolution

- `deploy/foo` → workload `foo`, namespace `N`. Istio labels traffic by
  `destination_workload` / `source_workload`, which equal the deployment name,
  so this maps directly.
- `pod/foo-abc123` → resolve the owner chain (Pod → ReplicaSet → Deployment)
  via `zig-klient` to recover the workload name, then query that workload. A
  single pod has no distinct Istio workload label.

### PromQL

For target workload `W` in namespace `N`, with `<W>`/`<N>` properly escaped:

**Inbound rate** (callers → W), server-reported:
```promql
sum by (source_workload, source_workload_namespace) (
  rate(istio_requests_total{
    reporter="destination",
    destination_workload="<W>", destination_workload_namespace="<N>"
  }[1m]))
```

**Inbound errors** (for success %): same query with
`response_code=~"5.."` added; success % = 1 − (errors / total) per peer.

**Inbound latency** (p50/p99):
```promql
histogram_quantile(0.99, sum by (le, source_workload) (
  rate(istio_request_duration_milliseconds_bucket{
    reporter="destination",
    destination_workload="<W>", destination_workload_namespace="<N>"
  }[1m])))
```

**Outbound** mirrors the above with `reporter="source"`,
`source_workload="<W>"`, `source_workload_namespace="<N>"`, grouped by
`destination_workload` / `destination_workload_namespace`.

## Render

Two stacked panels, redrawn every interval.

**Graph panel (top)** — mini topology map:
- target workload centered; callers flow in from the left, callees out to the
  right; req/s on the arrows.
- node color reflects aggregate health (green / yellow / red on success %).
- shows **top-N peers by rate** per direction (`--top`, default 6); a
  `+N more` marker when truncated.
- aggregate footer: total in r/s, overall success %, total out r/s.

**Detail table (bottom)** — every peer (full list), per direction:
columns `REQ/S · TREND (sparkline) · LOAD (magnitude bar) · OK% · P50 · P99`.
The sparkline uses a rolling in-memory history of each peer's req/s across
refreshes; success % is color-coded.

```
 deploy/foo · ns:ef-test                              2s · q quit
┌─ MAP ──────────────────────────────────────────────────────────┐
│  istio-ingressgw ──12.4 r/s──┐                                   │
│                              ▼                                   │
│  bar ──────────────3.1 r/s──▶┌─────────┐──5.0 r/s──▶ baz   97%   │
│                              │   foo   │                         │
│  auth-ws ──────────1.0 r/s──▶│ ●live   │──0.8 r/s──▶ qux  100%   │
│                              └─────────┘                         │
│        16.5 r/s in            99.4% ok          5.8 r/s out      │
└──────────────────────────────────────────────────────────────────┘
┌─ DETAIL ─────────────────────────────────────────────────────────┐
│ INBOUND            REQ/S  TREND      LOAD     OK      P50    P99   │
│  istio-ingressgw   12.4  ▆▇▅▆█▇▆▇  ███████  99.8%   8ms   42ms    │
│  bar                3.1  ▂▃▂▁▂▃▂▃  ██       100%    4ms   11ms    │
│ OUTBOUND           REQ/S  TREND      LOAD     OK      P50    P99   │
│  baz                5.0  ▄▅▄▆▅▄▅▆  ███████  97.2%  12ms   88ms    │
└──────────────────────────────────────────────────────────────────┘
```

**Resize-aware:** panels reflow to terminal width/height; the graph degrades
to a compact form on narrow terminals.

## Error handling

- **No Istio telemetry for the workload** → empty-state line:
  "no Istio telemetry — is this namespace sidecar-injected?" (expected on
  `cloud-core-dev`, where only `ef-test` is meshed today).
- **Prometheus not found / unreachable** → name the service it tried and
  suggest `--prometheus`.
- **Auth failure** (expired SSO, etc.) → surface `zig-klient`'s error with the
  hint to re-authenticate (`aws sso login`).
- **API-server service proxy forbidden by RBAC** → fall back to port-forward,
  or tell the user which permission is missing.

## Testing

- **Unit (no cluster):**
  - query builder — label escaping, query shape for in/out, latency quantiles.
  - target resolver — Pod→ReplicaSet→Deployment owner-chain logic.
  - Prometheus JSON parsing — instant-vector results, empty results, NaN.
  - model/aggregator — success % math, rolling sparkline buffer.
  - renderer formatting — number/latency formatting, bar/sparkline glyph
    selection (pure functions).
- **Integration (optional, gated):** against `cloud-core-dev` `ef-test`
  workloads where real Istio metrics exist.

## Open questions / risks

- libvaxis API stability against Zig 0.16.0 — confirm during planning.
- API-server service-proxy access may be restricted on some clusters
  (read-only RBAC); port-forward fallback mitigates.
- Istio metric label set can vary by telemetry config; queries target the
  standard v2 metric names present on `cloud-core-dev`.
