# kubectl-traffic

A kubectl plugin that shows a live, `top`-style per-workload traffic view —
inbound and outbound peers rendered as a topology graph plus a detail table,
updated on a configurable interval.

Designed for clusters running an **Istio service mesh** but **not Cilium**
(so Hubble is unavailable). It reads Istio's built-in Prometheus metrics
directly through the Kubernetes API-server service proxy — no port-forward,
no sidecar required on the client side.

---

## Requirements

| Requirement | Notes |
|---|---|
| **Zig 0.17.0** | Build toolchain |
| **kubeconfig** | A context authenticating with a bearer token (static or exec plugin such as `aws eks get-token`); see [Authentication](#authentication) |
| **Istio** | Target workload must be sidecar-injected |
| **Prometheus** | kube-prometheus-stack (or compatible) scraping Istio metrics |

Non-meshed workloads (no Istio sidecar) will show empty peer tables —
the metrics simply don't exist for them.

---

## Build & install

```sh
zig build
cp zig-out/bin/kubectl-traffic /usr/local/bin/
```

Once it is on `$PATH`, kubectl discovers it automatically:

```sh
kubectl traffic --help
```

---

## Usage

```
kubectl traffic <pod|deploy>/<name> [flags]

Flags:
  -n, --namespace <ns>      Target namespace (default: current context namespace)
      --interval <dur>      Refresh interval, e.g. 2s, 500ms (default: 2s, minimum: 250ms)
      --top <n>             Peers shown in graph per direction (default: 6)
      --prometheus <ref>    Prometheus service: svc.<ns>:<port> (default: prometheus-operated.monitoring:9090)
      --context <name>      Kubeconfig context (default: current-context)
      --server <url>        Talk to `kubectl proxy` at <url> instead of using kubeconfig
      --once                Collect once, print one frame to stdout, then exit
  -h, --help
```

### Examples

```sh
# Watch a Deployment in the current namespace
kubectl traffic deploy/my-api

# Watch a Pod in a specific namespace
kubectl traffic pod/my-api-6d7b9f-xkqp2 -n production

# Shorter interval, more peers shown
kubectl traffic deploy/my-api -n staging --interval 1s --top 10

# Custom Prometheus location
kubectl traffic deploy/my-api --prometheus kube-prometheus-stack-prometheus.monitoring:9090
```

Press `q` or `Ctrl-C` to quit.

---

## How it works

1. **Workload resolution** — a Pod target is resolved to its owning Deployment
   by inspecting `ownerReferences`.
2. **PromQL queries** — for each direction (inbound / outbound) the plugin
   issues three instant-vector queries against `istio_requests_total` and
   `istio_request_duration_milliseconds_bucket`:
   - request rate and 5xx rate (one query, split by response class)
   - p50 latency
   - p99 latency
3. **Kubernetes service proxy** — queries go through
   `GET /api/v1/namespaces/<ns>/services/<svc>:<port>/proxy/api/v1/query`
   so no direct network path to Prometheus is required.
4. **Model aggregation** — results are keyed by peer workload name and
   namespace; a ring-buffer history drives the sparkline columns.
5. **TUI render** — a hand-rolled ANSI backend redraws the topology graph
   and peer table in-place every interval.

---

## Prometheus location

There is no auto-discovery. The default target is the `prometheus-operated`
service in the `monitoring` namespace on port `9090` (created by
prometheus-operator / kube-prometheus-stack).

Override with `--prometheus svc.<namespace>:<port>`, for example:

```sh
kubectl traffic deploy/my-api --prometheus prometheus-operated.prometheus:9090
```

---

## Authentication

Supported: a bearer token from the kubeconfig user (`token`, or an `exec`
credential plugin), with the cluster CA from `certificate-authority` or
`certificate-authority-data`.

Not supported: client certificates (`client-certificate[-data]` /
`client-key[-data]`) and `insecure-skip-tls-verify`, because Zig's TLS client
can neither present a client certificate nor skip verification. The tool
detects these up front and exits with an error. Workaround: run
`kubectl proxy` and point the plugin at it:

```sh
kubectl proxy &
kubectl traffic deploy/my-api --server http://127.0.0.1:8001
```

---

## Testing

**Unit tests (no cluster required):**

```sh
zig build test
```

**Live integration test (requires a running cluster with Istio):**

```sh
KT_LIVE=1 \
KT_LIVE_WORKLOAD=my-api \
KT_LIVE_NS=my-namespace \
KT_LIVE_CONTEXT=my-kube-context \   # optional; omit to use current context
zig build test
```

The live test calls `collectTick` once against a real cluster and prints the
peer counts. It is automatically skipped when `KT_LIVE` is not set, so
`zig build test` is always safe to run without a cluster.
