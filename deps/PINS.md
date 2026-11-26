# Dependency pins

One place for the third-party charts and images that AgentWorkforce charts run
against. Chart versions live in [`pins.txt`](pins.txt), the one file that CI
(`scripts/ci/deps.sh`) and every smoke test read. Every smoke test (`ci/<suite>/smoke.sh`) and the umbrella charts use
these files. Bump a pin here, re-run the smoke tests, then update the consumers.

| Dependency | Chart (version) | Image | Values | Notes |
|---|---|---|---|---|
| CloudNativePG operator | `cnpg/cloudnative-pg` 0.29.1 | operator 1.30.1 | `cnpg-operator-values.yaml` | 11 CRDs; install first, as its own release |
| HoopDb Postgres | `cnpg/cluster` 0.9.0 | `ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9…` (PG 17.11) | `cnpg-cluster-values.yaml` | ships `vector` + `pg_trgm`; bootstrap creates the extensions and the Supabase roles (anon, authenticated, service_role) so the app role needs no extra privilege; only hook is a Helm test |
| Locker (S3) | `minio/minio` 5.4.0 | `cgr.dev/chainguard/minio:latest@sha256:e70b2b1e…` | `minio-values.yaml` | bucket hook off; `sessions-pipeline-worker` locker-init makes the bucket. MinIO no longer publishes public images; Chainguard's free tier is `:latest` only, so the digest is bumped by hand |
| OpenTelemetry collector | `open-telemetry/opentelemetry-collector` 0.178.0 | `otel/opentelemetry-collector-contrib:0.163.2` | `otel-values.yaml` | the image must track the chart's appVersion: 0.137.0 rejects this chart's config |

Repositories. `charts/sessions-pipeline` pulls the `cluster` and
`opentelemetry-collector` charts from the projects' OCI registries
(`oci://ghcr.io/cloudnative-pg/charts`, `oci://ghcr.io/open-telemetry/opentelemetry-helm-charts`),
which need no `helm repo add`; MinIO publishes no OCI chart, so it stays on
`https://charts.min.io/`. `scripts/selfhost/helm-deps.sh` builds the chart
dependencies without touching your Helm repositories. `pins.txt` and the smoke
tests still name the charts by these repository aliases:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add minio https://charts.min.io/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
```

None of these charts depend on Helm hooks for correctness, so all of them work
under Alchemy's `Kubernetes.HelmChart` (`helm template --no-hooks` +
server-side apply).
