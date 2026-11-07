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

## Release workflow

Charts are released via [helm/chart-releaser-action](https://github.com/helm/chart-releaser-action) published to GitHub Pages. When a PR is merged to `main`, the action packages the chart, creates a GitHub Release, and updates the `gh-pages` branch so the chart index stays current.

```bash
# Install from the repo after the first release has been published
helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update
helm repo update
helm search repo relayfile
```
