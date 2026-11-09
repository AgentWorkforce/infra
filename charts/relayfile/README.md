# Relayfile Helm Chart

[Relayfile](https://github.com/AgentWorkforce/relayfile) is a virtual filesystem sync service for agents. A single Go binary that signs you in, connects an integration, and serves a workspace file-sync API over HTTP — backed by Postgres in production or in-memory for development.

## TL;DR

```bash
helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update
# Development (in-memory, no Postgres):
helm install relayfile agentworkforce/relayfile \
  --set server.backendProfile=memory \
  --set secrets.internalHmacSecret=<strong-secret>
# Production: create a Kubernetes Secret first (keeps credentials out of shell history
# and Helm release metadata), then reference it — see "Installing the Chart" below.
```

## Prerequisites

- Kubernetes 1.21+
- Helm 3.8+
- A Postgres database (for the `production` backend profile)

## Architecture

Relayfile is a **single deployable binary** (`cmd/relayfile`). It:

- Serves HTTP on `:8080` with a `/health` endpoint used for liveness and readiness probes
- Stores workspace state, envelope queues, and writeback queues in Postgres (production profile) or fully in-memory (dev profile)
- Runs envelope-processing and writeback workers in-process — no separate worker deployment is needed
- Validates JWTs via a relayauth JWKS endpoint (`RELAYAUTH_JWKS_URL`) — relayauth is a separate external service; only its public JWKS URL is configured here
- Applies Postgres DDL (`CREATE TABLE IF NOT EXISTS`) on startup — no separate migration job is needed

> **Not deployed by this chart:** `relayfile-mount` and `relayfile-cli` are client-side tools that end users run on their own machines. They are not server-side workloads.

## Installing the Chart

### Add the Helm Repository

```bash
helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update
helm repo update
```

### Install (production profile, external secret)

Create a Kubernetes secret with your credentials:

```bash
kubectl create secret generic relayfile-credentials \
  --from-literal=RELAYFILE_INTERNAL_HMAC_SECRET=<strong-random-secret> \
  --from-literal=RELAYFILE_PRODUCTION_DSN='postgres://user:pass@host:5432/dbname?sslmode=require' \
  --from-literal=RELAYFILE_JWT_SECRET=<jwt-secret>
```

Then install the chart pointing to that secret:

```bash
helm install relayfile agentworkforce/relayfile \
  --set secrets.existingSecret=relayfile-credentials \
  --set auth.jwksUrl=https://auth.relay.example.com/.well-known/jwks.json \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=relayfile.example.com \
  --set "ingress.hosts[0].paths[0].path=/" \
  --set "ingress.hosts[0].paths[0].pathType=Prefix"
```

### Install (development / in-memory profile)

```bash
helm install relayfile-dev agentworkforce/relayfile \
  --set server.backendProfile=memory \
  --set secrets.internalHmacSecret=dev-only-secret
```

## Uninstalling the Chart

```bash
helm uninstall relayfile
```

## Parameters

### Image

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Image repository | `ghcr.io/agentworkforce/relayfile` |
| `image.tag` | Image tag (defaults to `Chart.appVersion`) | `""` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `imagePullSecrets` | Image pull secrets | `[]` |

### Replica / Autoscaling

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas (ignored when HPA is enabled) | `1` |
| `autoscaling.enabled` | Enable HPA | `false` |
| `autoscaling.minReplicas` | HPA minimum replicas | `1` |
| `autoscaling.maxReplicas` | HPA maximum replicas | `5` |
| `autoscaling.targetCPUUtilizationPercentage` | HPA CPU target | `80` |
| `verticalPodAutoscaler.enabled` | Enable VPA | `false` |

### Server configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `server.port` | Port the server listens on; used for containerPort and default `RELAYFILE_ADDR` (Service port is configured separately via `service.port`) | `8080` |
| `server.addr` | Full TCP bind address (`RELAYFILE_ADDR`); overrides `server.port` derivation when set. **Do not use a loopback address** — kubelet probes and the Service target the pod IP, not loopback | `""` |
| `server.backendProfile` | Storage profile (`RELAYFILE_BACKEND_PROFILE`): `production` (Postgres), `memory` (dev/in-process), `durable-local` (file; requires writable volume + `readOnlyRootFilesystem: false`), `custom` (BYO DSNs) | `production` |
| `server.envelopeWorkers` | In-process envelope worker count (`RELAYFILE_ENVELOPE_WORKERS`) | `2` |
| `server.writebackWorkers` | In-process writeback worker count (`RELAYFILE_WRITEBACK_WORKERS`) | `2` |
| `server.providerMaxConcurrency` | Max concurrent provider operations (`RELAYFILE_PROVIDER_MAX_CONCURRENCY`) | `4` |
| `server.rateLimitMax` | Max requests per rate-limit window (`RELAYFILE_RATE_LIMIT_MAX`) | `""` |
| `server.rateLimitWindow` | Rate-limit window duration, e.g. `1m` (`RELAYFILE_RATE_LIMIT_WINDOW`) | `""` |
| `server.maxBodyBytes` | Max request body size in bytes (`RELAYFILE_MAX_BODY_BYTES`) | `""` |

### Secrets / credentials

Prefer using `secrets.existingSecret` in production; the chart-managed secret is convenient for development only.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `secrets.existingSecret` | Name of an existing Secret; chart skips Secret creation when set | `""` |
| `secrets.internalHmacSecret` | HMAC secret for the internal webhook endpoint (`RELAYFILE_INTERNAL_HMAC_SECRET`) — **required in production** | `""` |
| `secrets.productionDsn` | Postgres connection string (`RELAYFILE_PRODUCTION_DSN`) — required when `server.backendProfile=production` | `""` |
| `secrets.jwtSecret` | JWT secret for workspace tokens (`RELAYFILE_JWT_SECRET`) | `""` |

### External auth (relayauth)

relayauth is a separate service; only its public JWKS endpoint is configured here.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `auth.jwksUrl` | JWKS URL served by relayauth (`RELAYAUTH_JWKS_URL`) | `""` |

### Providers

Configure only the providers you use.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `providers.notion.token` | Notion integration token (`RELAYFILE_NOTION_TOKEN`) | `""` |
| `providers.notion.baseUrl` | Override Notion API base URL (`RELAYFILE_NOTION_BASE_URL`) | `""` |
| `providers.notion.apiVersion` | Override Notion API version header (`RELAYFILE_NOTION_API_VERSION`) | `""` |

### Service

| Parameter | Description | Default |
|-----------|-------------|---------|
| `service.type` | Kubernetes Service type | `ClusterIP` |
| `service.port` | Service port | `8080` |
| `service.annotations` | Service annotations | `{}` |

### Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable Ingress | `false` |
| `ingress.className` | IngressClass name | `""` |
| `ingress.annotations` | Ingress annotations | `{}` |
| `ingress.hosts` | Ingress hosts and paths | `[]` |
| `ingress.tls` | Ingress TLS configuration | `[]` |

### Other

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources` | Resource requests and limits; defaults to `requests: {cpu: 100m, memory: 128Mi}` so HPA utilization metrics are always computable. Override or remove if a LimitRange supplies defaults | `{requests: {cpu: 100m, memory: 128Mi}}` |
| `podDisruptionBudget.enabled` | Enable PodDisruptionBudget | `false` |
| `networkPolicy.enabled` | Enable NetworkPolicy | `false` |
| `serviceAccount.create` | Create a ServiceAccount | `true` |
| `nodeSelector` | Node selector | `{}` |
| `tolerations` | Tolerations | `[]` |
| `affinity` | Affinity rules | `{}` |

## Managed Go introspection and verified PostgreSQL

Both modes are optional. Empty `auth.mode` and `postgres.enabled=false` retain
the existing server and durable-actors behavior. They do not select optional
Control features or implement the native kind add-on lifecycle.

Set `auth.mode=introspection` for the Go server to verify bearers using Control
without RelayAuth. Provide a bare HTTP(S) `auth.introspection.internalUrl`, the
exact HTTPS `publicOrigin` accepted in Control's introspection audience list,
and `secretRef.name/key` for the existing introspection service credential.
The server appends `/internal/v1/auth/introspect`; it reads the service credential
from a read-only projected file. No JWKS or JWT credential is configured in this
mode. `auth.jwksUrl` conflicts with it. `timeoutSeconds` is 1–30 and the positive
cache's `cacheTtlSeconds` is 0–60; use 0 to disable caching. Revocation acceptance
can otherwise last until the documented cache TTL expires.

Filesystem authority remains separate: a normal History user token does not
gain `fs:*` scopes from this setting. An authorized workspace owner/admin issues
a finite-lived Control token with purpose `relayfile-agent`, `agent_name` and
the exact files audience through the supported token API. The chart neither
issues nor stores such client tokens.

For verified PostgreSQL serving, complete the official external owner bootstrap
first. Use one dedicated database on the existing PostgreSQL instance, a
restricted NOLOGIN database/schema owner and a distinct restricted LOGIN runtime
role. The official `relayfile postgres bootstrap` command creates the supported
objects and grants under that owner; run `relayfile postgres verify` as runtime.
The chart creates no database, roles, grants or bootstrap Job and has no owner
credential field or mount.

Then set `postgres.enabled=true`, the public `database`, `ownerRole` and
`runtimeRole` names, `runtimeSecret.name/key`, and `ca.configMap/key/sha256`.
The Pod projects only the selected URL key from the runtime Secret. Its value must name the
runtime identity, explicit host/port/database, `sslmode=verify-full` and
`sslrootcert=/etc/relayfile-postgres/ca.crt`. The supplied CA SHA256 is 64 lowercase
hex characters over the exact public CA bytes. Secret contents cannot be checked
at render time: the official serving command checks the URL, CA bytes, actual
identity, schema, privileges and persisted data before starting workers or the
listener. Wrong credentials, CA, hostname or database authority refuse startup.
This mode requires one replica, disables autoscaling and uses Recreate rollouts;
concurrent processes writing the stored workspace snapshot are not qualified.

The generated command is `relayfile postgres serve` with public contract flags
and `--dsn-file /var/run/relayfile-postgres/database-url`. DSN and introspection
credentials are projected read-only with group-readable mode and a default
`fsGroup=1000`; an explicit existing `podSecurityContext.fsGroup` is preserved.
No new credential is placed in argv or environment values. The unchanged server
still requires `RELAYFILE_INTERNAL_HMAC_SECRET` through the existing Secret env
reference; optional provider Secret refs retain their existing behavior.
Managed Go modes explicitly set `RELAYFILE_DEV_MODE=false`; an empty HMAC
credential must refuse startup rather than enable the development secret.

These modes require an explicit `image.digest` and empty `image.tag`, selecting
a separately qualified image with the matching official runtime contract. The
legacy default tag is not a qualification for these commands. Both are Go-only;
durable-actors refuses them. Managed connection/auth names cannot appear again in
`extraEnv`, and opaque `extraEnvFrom` is refused. `secrets.existingSecret` is
required; no new inline credential Secret is rendered. With verified PostgreSQL,
the old `RELAYFILE_PRODUCTION_DSN` env and independent storage overrides are not
configured. Auth-only and verified-database-only configurations are also supported;
a native add-on adapter must explicitly require both when it is implemented.

`/health` remains HTTP liveness. Startup verification is not continuous database
readiness, a migration system, a backup system or end-to-end deployment proof.
See [the render fixture](ci/verified-postgres-values.yaml) for public placeholders;
its image and CA hashes are not deployable artifact or PKI selections.

## Release workflow

Charts are released via [helm/chart-releaser-action](https://github.com/helm/chart-releaser-action) published to GitHub Pages. When a PR is merged to `main`, the action packages the chart, creates a GitHub Release, and updates the `gh-pages` branch so the chart index stays current.

```bash
# Install from the repo after the first release has been published
helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update
helm repo update
helm search repo relayfile
```
