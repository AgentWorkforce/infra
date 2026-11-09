# relayfile-control

Packaging for [relayfile-control](https://github.com/AgentWorkforce/relayfile-control),
the optional Relayfile webhook ingest service and Flows API. It is not part of the
`agent-relay` umbrella. It runs one replica and makes no HA claim. Flows and the
Ingress are off by default, and the chart creates no Secret.

## Install inputs

| Value | Renders | Notes |
| --- | --- | --- |
| `image.digest` | image reference | Required `sha256:<64 hex>`; tags are not accepted |
| `config.relayfileBaseUrl` | `RELAYFILE_BASE_URL` | Required http(s) URL |
| `config.relaycontrolBaseUrl` | `RELAYCONTROL_BASE_URL` | Required bare http(s) origin |
| `config.publicOrigin` | `RELAYFILE_CONTROL_PUBLIC_ORIGIN` | Required with `flows.enabled`; list it in relay-control's `introspection.audiences` |
| `flows.enabled` | `FLOWS_ENABLED` | Off by default |
| `flows.encryptionKeyId` | `RELAYFILE_CONTROL_ENCRYPTION_KEY_ID` | Required with `flows.enabled` |
| `flows.workerRelaycastUrl` or `flows.relaycastPublicUrl` | `SELFHOST_FLOWS_WORKER_RELAYCAST_URL` or `RELAYCAST_PUBLIC_URL` | One is required with `flows.enabled` |
| `flows.dashboardUrl` | `SELFHOST_DASHBOARD_URL` | Optional; needed for cookie-authenticated browser writes under `/cloud` |
| `flows.storage` | `SELFHOST_FLOWS_STORAGE` | Only `postgres` is offered |
| `existingSecret` | all Secret env | Required; the chart takes no Secret values |

The chart always renders `MIGRATE_ON_START=1` and keeps the admin listener on
`127.0.0.1:3101`. Migrations run before the server listens, under an advisory lock.

`existingSecret` holds these data keys, renamed through `secretKeys.*`:

| Key | Requirement |
| --- | --- |
| `DATABASE_URL` | Required; its own database, for example `relayfile_control` |
| `RELAYFILE_INTERNAL_HMAC_SECRET` | Required; same value as the Relayfile server |
| `RELAYFILE_CONTROL_ADMIN_TOKEN` | Required; a comma list allows rotation |
| `RELAYCONTROL_SERVICE_TOKEN` | Required |
| `RELAYCONTROL_INTROSPECT_SECRET` | With Flows; at least 32 bytes |
| `RELAYFILE_CONTROL_BROKER_SECRET` | With Flows; at least 32 bytes, shared with relay-control, different from the introspection secret |
| `RELAYFILE_CONTROL_ENCRYPTION_KEY` | With Flows; 32 bytes as hex or base64 |
| set `secretKeys.previousEncryptionKey` | Optional, with `flows.previousEncryptionKeyId`, during a key rotation |
| set `secretKeys.telemetrySecret` or `secretKeys.runtimeVerifySecret` | Optional; at least 32 bytes; each enables its internal route |
| set `secretKeys.githubWebhookSecret` and the other provider keys | Optional; an unset provider answers `503 ingress_not_configured` |

A render cannot see Secret contents. A missing key stops the pod with
`CreateContainerConfigError`, and an invalid secret stops the server at startup.
The server refuses equal introspection, broker, telemetry and runtime-verify
secrets; the chart refuses two of them naming the same Secret key.

`postgresCa` mounts a private Postgres CA bundle for `sslmode=verify-full`, as in
the `relayhistory` chart.

## Ingress and NetworkPolicy

`ingress.enabled` is off and requires `flows.enabled`. It routes
`/api/v1/{flows,workers,workflows}` and the `/cloud/api/v1/...` aliases to this
Service. On the shared EKS ALB, leave it off and set
`EKS_ALB_RELAYFILE_CONTROL=true` for `scripts/selfhost/eks-alb-ingress.sh`; set
`alb.ingress.kubernetes.io/healthcheck-path: /healthz` in `service.annotations`.

`networkPolicy.enabled` defaults to true with restricted egress, so
`networkPolicy.additionalEgress` must admit the database or the render fails.
`networkPolicy.ingressFrom` replaces the same-namespace default, so keep a
`podSelector` peer for relay-control and add the ALB subnets for IP targets.

```sh
helm lint --strict charts/relayfile-control \
  -f charts/relayfile-control/ci/default-values.yaml
```
