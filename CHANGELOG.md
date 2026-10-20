# Changelog

## 0.1.1 - 2026-10-20

- Base64-decode kubeconfig `certificate-authority-data`, `client-certificate-data`, and `client-key-data` into PEM bytes and wire `insecure-skip-tls-verify`.
- Free temporary pod list in `resolvePod` after selecting the target pod.
- Key peers by `(name, namespace)` so workloads with identical names in different namespaces do not collide, and decay idle edge rates across poll ticks.
- Replace unguarded JSON unwraps in `prom_client` with `error.BadResponse` and guard `sparkline`, `bar`, and `table` renderers against non-finite values and narrow buffers.
- Add CI workflow for Linux and macOS.

## 0.1.0 - 2026-10-19

- Initial release of `kubectl-traffic`.
