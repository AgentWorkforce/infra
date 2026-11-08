# Self-hosted Relayflows

Status: partially shipped. `components.relayflows` adds the `relayflows` chart
to the `agent-relay` suite as an opt-in component (off by default). Standalone
mode works against a self-hosted install today; `cloudWorker` mode is blocked
on control-plane endpoints the self-host API does not yet implement.

## Wiring

`charts/agent-relay/Chart.yaml` depends on `relayflows` 0.2.4 under the
`components.relayflows` condition. `relayflows.*` values pass through to the
subchart unchanged; `charts/agent-relay/values-gcp.yaml` carries a commented
reference block. Relayfile remains outside the suite.

## What works today: standalone mode

`mode: standalone` (the default) renders a Kubernetes Job — or a CronJob under
`standalone.cron.enabled` — that runs `flows run` (or `flows resume`) entirely
in-cluster. It never contacts a control plane: the Job spec forces
`FLOWS_CLOUD_MIRROR` and `AGENT_RELAY_TELEMETRY_DISABLED` off and the extraEnv
guard reserves those names
(`charts/relayflows/templates/standalone/_jobspec.tpl`).

The operator supplies:

- Exactly one flow source: `standalone.flow.path` inside the image,
  `standalone.flow.content` (chart-managed ConfigMap), or
  `standalone.flow.existingConfigMap` — unless `standalone.resumeRunId` is set.
- An image containing the flow and every harness CLI the flow invokes. The
  stock `node` image only works with `runtimeInstaller.enabled`, which
  npm-installs the pinned `relayflows` runtime at pod start — a bootstrap
  convenience, not a production shape.
- A `ReadWriteOncePod` PVC for the run journal so `flows resume` can take over
  after a node drain or restart.
- Model/provider credentials via `extraEnv`/`extraEnvFrom` (for example an
  ESO-created Secret holding `ANTHROPIC_API_KEY`).

The flow can reach the suite's in-cluster services (`relaycast`,
`relay-control`, `relayhistory`) over plain ClusterIP service DNS; nothing
in the chart hard-codes those URLs, so credentials and endpoints are passed
explicitly as env.

## What is blocked: cloudWorker mode

`mode: cloudWorker` renders a long-running Deployment that runs
`agent-relay cloud worker register` (once, persisting registration to the PVC)
then `agent-relay cloud worker start` against `worker.cloudUrl`
(`charts/relayflows/templates/_helpers.tpl` `relayflows.workerScript`). The CLI
speaks the hosted worker assignment protocol — all paths are appended to
`cloudUrl` (`relay` repo, `packages/cloud/src/worker.ts`):

- `POST {cloudUrl}/api/v1/workers/register` — body `{enrollmentToken, name,
  hostInfo?}`; returns `{workerId, workerToken, heartbeatIntervalMs}`
  (worker.ts:332).
- `POST {cloudUrl}/api/v1/workers/{workerId}/heartbeat` (worker.ts:382).
- `GET {cloudUrl}/api/v1/workers/{workerId}/queue` — SSE stream of `ping`,
  `assignment`, `timeout`, `revoke` events (worker.ts:599).
- `POST {cloudUrl}/api/v1/workers/{workerId}/assignments/{runId}/ack`
  (worker.ts:413) and `.../status` (worker.ts:438).
- `GET|HEAD {cloudUrl}/api/v1/workers/{workerId}/assignments/{runId}/storage/
  {objectKey}` — assignment artifacts (worker.ts:465, :493).

Every post-registration call authenticates with `Authorization: Bearer
{workerToken}` (worker.ts:282). The hosted control plane also exposes
`POST /api/v1/workers/enrollment-tokens` (session auth, org owner/admin) to
mint the one-time enrollment token
(`cloud` repo, `packages/web/app/api/v1/workers/`).

The self-host control plane (`relay-control`, source
`cloud-selfhost-current/packages/selfhost-api/src/app.ts`) implements none of
this family. Its route table covers auth/device flow, organizations,
memberships, workspace resolve/runtime, session search and relayhistory
session issuance only — a request to `/api/v1/workers/*` (or
`/cloud/api/v1/workers/*`, which `normalizeRoutePath` maps onto the same
table) returns `404 not_found`. `store.ts` has no worker or enrollment state.

Until selfhost-api grows `POST /api/v1/workers/register`, the per-worker
`heartbeat`, `queue`, `assignments/{runId}/ack|status|storage` endpoints and
an enrollment-token minting path, `cloudWorker` can only point at a control
plane that already implements the protocol (today: hosted Agent Relay Cloud —
the chart's default `worker.cloudUrl`). Pointing it at `http://relay-control`
renders and deploys but the worker exits: `register` gets a 404 and no
registration state is persisted.

## Security model

- No credentials in values. The worker enrollment token comes from
  `credentials.existingSecret` (key `credentials.existingSecretKey`, default
  `AGENT_RELAY_WORKER_ENROLLMENT_TOKEN`). Setting
  `credentials.enrollmentToken` instead renders a chart-managed Secret — the
  only Secret material this suite renders, and the proof render asserts none
  (`ci/agent-relay/render.sh`), which stays true while
  `components.relayflows` is off or `existingSecret` is used.
- The enrollment token is one-time: the env ref is `optional: true` so the
  spent Secret may be deleted after first registration; registration state
  (`cloud-workers.json` with the durable `workerToken`) lives on the PVC under
  `AGENT_RELAY_HOME`.
- Worker identity is pinned: `worker.name` plus `worker.cloudUrl` must stay
  stable while reusing a PVC, and the Deployment uses `Recreate` so one worker
  identity is never consumed concurrently.
- Standalone pods run unprivileged (`runAsNonRoot`, read-only rootfs, dropped
  capabilities), automount no service-account token, and keep hosted
  publication and telemetry disabled by default.
- The `workerToken` is a bearer credential scoped to one worker identity; the
  queue stream and assignment status/storage calls authorize nothing broader.

## Enabling

```yaml
components:
  relayflows: true
relayflows:
  mode: standalone
  image:
    repository: <registry>/<project>/relayflows-flows
    tag: "<immutable tag>"
  runtimeInstaller:
    enabled: false
  standalone:
    flow:
      path: /opt/flows/example.flow.ts
```

See `charts/agent-relay/values-gcp.yaml` for the commented cloudWorker shape
and `self-hosted/requirements.yaml` (`opt.agent-relay.relayflows`,
`opt.relayflows.*`, `req.relayflows.*`) for the full requirement model.
