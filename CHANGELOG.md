# Changelog

## 0.1.2 - 2026-10-25

- Correction to 0.1.1: client certificates (`client-certificate`, `client-certificate-data`, `client-key`, `client-key-data`) and `insecure-skip-tls-verify` were never supported; zig-klient rejects them because Zig's TLS client cannot present a client certificate or skip verification. Supported authentication is a bearer token (static `token` or an exec-credential plugin) with the cluster CA from `certificate-authority` or `certificate-authority-data`, or `--server` pointing at `kubectl proxy`. Such kubeconfigs are now detected before any request and the tool exits with an explanation suggesting `kubectl proxy` and `--server`. A client certificate configured alongside a token or exec plugin is ignored and the token is used.
- Sanitize Prometheus label text, names, and the title before writing them to the terminal: C0 controls, DEL, C1 controls (U+0080-U+009F), and invalid UTF-8 become `?`, and each span is length-capped, so label values cannot inject escape sequences.
- Validate pod, deployment, namespace, and Prometheus service names as DNS-1123 at the CLI and before building API-server paths.
- Escape `\n` and `\r` in PromQL label values.
- Add `--context` to pick a kubeconfig context.
- Restore the terminal on SIGTERM, SIGINT, and SIGHUP; suppress log output while the full-screen view is active.
- A failed refresh keeps the previous values on screen and shows the error in a status line instead of logging over the view and zeroing rates.
- Fix `NoSpaceLeft` on long workload or namespace names in the title and graph footer.
- Enforce a 250ms minimum for `--interval`.
- Fetch request and 5xx rates in one query per direction (3 queries per direction instead of 4).
- Drop peers that have had no traffic for 30 consecutive refreshes.
- Help text and README now state the actual default Prometheus target (`prometheus-operated.monitoring:9090`) instead of claiming auto-discovery.

## 0.1.1 - 2026-10-20

- Base64-decode kubeconfig `certificate-authority-data`, `client-certificate-data`, and `client-key-data` into PEM bytes and wire `insecure-skip-tls-verify`.
- Free temporary pod list in `resolvePod` after selecting the target pod.
- Key peers by `(name, namespace)` so workloads with identical names in different namespaces do not collide, and decay idle edge rates across poll ticks.
- Replace unguarded JSON unwraps in `prom_client` with `error.BadResponse` and guard `sparkline`, `bar`, and `table` renderers against non-finite values and narrow buffers.
- Add CI workflow for Linux and macOS.

## 0.1.0 - 2026-10-19

- Initial release of `kubectl-traffic`.
