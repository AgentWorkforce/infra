# Relaycast Helm chart

This chart runs the portable Relaycast core on Kubernetes. In the default
(legacy credentials) and `credentials.authority=self` modes it has no
dependency on Relayflows, RelayAuth, Relayfile, the Sessions Pipeline, or a cloud provider.
`credentials.authority=relayauth` (model B, below) adds a runtime dependency on
a reachable RelayAuth deployment.

The self-host runtime is a single Node process backed by SQLite and a local
uploaded-file store, both on one persistent volume. The chart therefore allows
exactly one replica and upgrades with `Recreate`. `runtime.backend` selects
`sqlite` (the default), `durable-actors` (see `docs/self-hosted-durable-actors.md`)
or [`postgres`](#postgresql-backend), and the chart refuses names of backends
that are not implemented.

## Defaults

- **Image:** pinned by immutable multi-arch digest (`linux/amd64`, `linux/arm64`).
- **Secrets:** they come from your `existingSecret` and are mounted read-only as
  files (`*_FILE`). The chart never renders a secret value.
- **Anonymous `POST /v1/workspaces`:** off (`404`). You create workspaces
  through the in-cluster admin API, as shown in [First run](#first-run).
- **Exposure:** a `ClusterIP` Service, plus a NetworkPolicy that admits only pods
  in the release namespace.
- **Persistence:** the data PVC carries `helm.sh/resource-policy: keep`.

## Quickstart

```bash
kubectl create namespace relaycast

# Two secrets, generated in place: internal admin bearer (>= 32 chars) and the
# workspace-bootstrap derivation secret. Keep both stable across upgrades.
kubectl -n relaycast create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"

helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update
helm install relaycast agentworkforce/relaycast -n relaycast \
  --set baseUrl=https://relay.example.com \
  --set existingSecret=relaycast-secrets
```

Relaycast embeds `baseUrl` in signed file URLs and A2A cards, so set it to the
origin clients will use. For a cluster-internal deployment with no public
origin, use the Service name over http:

```bash
  --set baseUrl=http://relaycast.relaycast.svc:8787 --set allowInsecureBaseUrl=true
```

### First run

Create the first workspace through the admin API from inside the pod. The
internal secret never leaves the cluster. The response holds the only copy of
the workspace key (`rk_live_…`), so move it into your secret manager and then
delete `workspace.json`:

```bash
umask 077
kubectl -n relaycast exec deploy/relaycast -- node -e '
  const s = require("fs").readFileSync("/run/secrets/relaycast/internal-secret", "utf8").trim();
  fetch("http://127.0.0.1:8787/internal/workspaces", { method: "POST",
    headers: { authorization: "Bearer " + s, "content-type": "application/json" },
    body: JSON.stringify({ name: process.argv[1] }) })
    .then(async (r) => { process.stdout.write(await r.text() + "\n"); process.exitCode = r.status === 201 ? 0 : 1; });
' my-team > workspace.json
```

The command is safe to rerun only if you mean it: each call creates another
workspace with its own key.

### Connecting agents

The real-time receive path is the node transport. Agents use it by default
through `@relaycast/sdk`. The raw protocol is:

1. Register the agent: `POST /v1/agents` with the workspace key.
2. Mint the agent's node token: `POST /v1/agent/node-token`.
3. Connect to `/v1/node/ws?token=nt_live_…` and send a `node.register` frame.
4. Messages arrive as `deliver` frames. Acknowledge them with `delivery.ack`.

The frame shapes are in Relaycast's
[self-hosting guide](https://github.com/AgentWorkforce/relaycast/blob/main/docs/self-hosting.md#5-connecting-clients).
`GET /v1/ws` is only for observer tokens. It refuses agent tokens and
workspace keys.

## Credential format and authority (ar_ / model B)

By default Relaycast issues and verifies legacy credentials locally. With
`credentials.format=ar` an authority is required:

- `credentials.authority=relayauth` (model B): RelayAuth owns the `ar_`
  credential tag keyring and pushes `ar_ws_` workspace keys into Relaycast.
  Relaycast verifies `ar_` tags through RelayAuth's remote CredentialTagger
  (`RELAYCAST_RELAYAUTH_URL` + `RELAYCAST_RELAYAUTH_TOKEN_FILE`).
- `credentials.authority=self`: Relaycast verifies `ar_` tags against a local
  keyring (`secretKeys.credentialKeyring`, mounted as
  `RELAYCAST_CREDENTIAL_KEYRING_FILE`).

A mounted `secretKeys.credentialKeyring` always takes precedence over the
remote tagger. `ar_` custody requires a `>=12.3.x` engine image; the pinned
default (engine 12.7.0) satisfies it, so no `image.digest` override is needed.

```yaml
credentials:
  format: ar
  authority: relayauth
  relayauth:
    url: http://relayauth.relayauth.svc:8787
secretKeys:
  relayauthToken: relaycast-relayauth-token   # key in existingSecret
```

## Durable-actors gateway availability

With an object file store (`gcs` or `s3`),
`runtime.durableActors.gateway.replicaCount` may be greater than one. The chart
then renders a `maxUnavailable: 1` PodDisruptionBudget automatically. Enable
`runtime.durableActors.gateway.topologySpread` to generate a zone (or hostname)
spread constraint whose selector is derived from this release's labels. The
generic root `topologySpreadConstraints` remains available when the generated
shape is disabled. Local files and the development runtime remain one replica
and render no PDB.

## Keyed workspace creates on durable-actors

With `runtime.backend: durable-actors`, a keyed workspace create
(`Idempotency-Key`) needs the workspace bootstrap secret on the gateway **and**
on every actor, with the same bytes. Without it, keyed creates answer 503
`workspace_create_idempotency_unavailable`; unkeyed creates are unaffected.
Requires gateway and deployer images from relaycast PR #622 or later.

```yaml
secretKeys:
  # existingSecret key; becomes RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET on the gateway
  workspaceBootstrapSecret: relaycast-actors-workspace-bootstrap-secret
# RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED ("true"/"false"; default false)
bootstrapProofRequired: false
```

The chart cannot write or read the actor env Secret
(`runtime.durableActors.actorEnvSecrets`), so operators must provision the same
values there. In the following example, replace **every** sample assignment with
the configured namespace, gateway `existingSecret`,
`secretKeys.workspaceBootstrapSecret`, and the actor Secret's actual namespace
and name. These names are independent; do not assume the sandbox namespace is
`$NS-$RELEASE` on a customized deployment.

```bash
NS=relay-system
GATEWAY_SECRET=relaycast-secrets
BOOTSTRAP_KEY=relaycast-actors-workspace-bootstrap-secret
ACTOR_NS=relay-system-relay
ACTOR_SECRET=relaycast-actor-env
PROOF_REQUIRED=false # must equal bootstrapProofRequired in the Helm values
# First-time provisioning only. Reuse the existing bytes on an established install.
v=$(openssl rand -base64 48 | tr -d '\n') # no trailing newline
kubectl -n "$NS" patch secret "$GATEWAY_SECRET" --type merge \
  -p "{\"stringData\":{\"$BOOTSTRAP_KEY\":\"$v\"}}"
kubectl -n "$ACTOR_NS" patch secret "$ACTOR_SECRET" --type merge \
  -p "{\"stringData\":{\"RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET\":\"$v\",\"RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED\":\"$PROOF_REQUIRED\"}}"
unset v
```

For an existing actor installation, use a maintenance window and stop workspace
creation/replay traffic before changing the proof policy or provisioning these
values. Updating a Secret does not refresh an existing actor process. Follow this
order before resuming traffic:

1. Update the actor Secret first. Keep an established bootstrap secret stable:
   changing it derives different workspace IDs and is not a supported key
   rotation procedure.
2. Render the proposed release with its complete reviewed values and identify
   the **exact** `Job` carrying `app.kubernetes.io/component: actors-deploy` in
   that release's namespace. After verifying its release ownership and that no
   deployer is running, delete that completed Job by name:
   `kubectl -n "$NS" delete job "$DEPLOY_JOB"`, where `DEPLOY_JOB` is that
   inspected name. Reapply the reviewed release so the Job is recreated, then
   wait for that exact Job to complete. Secret contents and bootstrap policy
   are not in its pod-template hash: an unchanged `helm upgrade` alone does
   **not** rerun it. A changed deployer input can create a new Job instead; still
   inspect and wait for the newly rendered Job.
3. Complete the actor bundle rollout using the durable-actors lifecycle
   procedure for this project. Restart/replace every already-running Workspace
   actor for the project so it reads the updated Secret; a completed deployer
   Job alone does not prove those processes have refreshed. Verify replacement
   actor readiness before rolling the gateway. Preserve actor storage and PVCs.
4. Apply the matching gateway values and restart the gateway after the actor
   rollout. Secret contents alone do not change its pod template either. For
   the development sidecar, restart the gateway pod so both containers reload.
   Verify keyed create and replay return the same workspace/credential, and
   verify a missing/wrong proof is refused when required, before resuming traffic.

Do not proceed with a Secret/policy update if the project has no qualified actor
restart/rollout procedure. This chart change does not perform or qualify that
live cutover.

`bootstrapProofRequired: true` requires an anonymous keyed `POST /v1/workspaces`
to send `X-Workspace-Bootstrap-Secret`; the gateway refuses a missing or wrong
proof with 401 `workspace_create_bootstrap_secret_invalid` before any actor
call. It only matters with `publicWorkspaceCreate: true` (never behind an
edge, which denies `/v1/workspaces`). Unkeyed creates and keyed
`POST /internal/workspaces` never ask for proof. Known edge: a weak key (fewer
than 32 characters) sent with a missing or wrong proof gets 401, not 400
`key_too_weak`, because the proof is checked first.

The full request/answer table is in
[docs/self-hosted-durable-actors.md](../../docs/self-hosted-durable-actors.md#workspace-bootstrap-secret-actor-mode).

## Public ingress

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt   # cert-manager issues and renews the TLS Secret
  hosts: [relay.example.com]
  tls:
    - secretName: relay-example-com-tls
      hosts: [relay.example.com]
networkPolicy:
  ingressFrom:   # required with ingress: admit the controller
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Rendering is refused unless all of the following hold:

- `ingress.tls` is set, or `ingress.externalTls=true` when a load balancer in
  front of the controller terminates TLS
- `publicWorkspaceCreate=false`
- `baseUrl` is HTTPS
- `baseUrl`'s host is in `ingress.hosts`
- `networkPolicy.ingressFrom` is set (when the NetworkPolicy is on)

The Ingress sends every path to Relaycast except two:

- `/internal` (Prefix): the admin API.
- `/v1/workspaces` and `/v1/workspaces/` (Exact): anonymous workspace creation.

Those two go to `<fullname>-deny` (`relaycast-deny` for a release named `relaycast`), a Service with no endpoints. The
controller answers `503`, so the request never reaches the engine. This works
on any controller that follows the Ingress path-precedence rules. On
ingress-nginx, encoded and dot-segment spellings such as `/%69nternal`,
`//internal`, `/v1/../internal` and `/v1/%77orkspaces` are blocked too. Setting
`networkPolicy.ingressFrom` replaces the same-namespace default, so if
in-namespace clients also need access, list them too.

## Backups and restore

```yaml
backup:
  enabled: true
  schedule: "17 3 * * *"
  keep: 7
```

The backup CronJob runs the Relaycast image on the Relaycast pod's node, which
`ReadWriteOnce` requires. It takes an online snapshot through SQLite's backup
API while the engine keeps running, then checks the copy with
`PRAGMA integrity_check`. It copies `relaycast-files/` next to the snapshot and
writes everything to `relaycast-<UTC timestamp>/` on the backup PVC, marking the
directory `COMPLETE` last. Only the newest `keep` complete backups are kept.

Uploaded files are copied both before and after the snapshot, so every upload
the snapshot references is included. A lock on the backup volume means only
one backup runs at a time, including manual runs. A failed run's partial copy
is removed. If the volume is full, the run prunes to `keep - 1` and retries
once; it never deletes the last complete backup. The
backup PVC is also mounted read-only in the Relaycast pod, so it binds at
install time. Copy that PVC off-cluster with your usual volume-snapshot or
object-storage tooling.

Run a backup now:

```bash
kubectl -n relaycast create job --from=cronjob/relaycast-backup relaycast-backup-manual
kubectl -n relaycast logs job/relaycast-backup-manual   # {"backup":"relaycast-20261031T000952Z",...}
kubectl -n relaycast exec deploy/relaycast -- ls /backup
```

To restore, run [`ci/relaycast/restore.sh`](../../ci/relaycast/restore.sh). It is
the exact procedure CI runs on kind:

```bash
NS=relaycast RELEASE=relaycast BACKUP=relaycast-20261031T000952Z ci/relaycast/restore.sh
```

The script does the following:

1. Suspends the backup CronJob and waits for any running backup to finish.
2. Scales the Deployment to 0 and waits for the pod to exit.
3. Runs a one-off Job that moves the current `relaycast.db*` and
   `relaycast-files/` aside to `/data/pre-restore-<ts>/`. It never deletes
   them. The Job uses the Deployment's image, pull secrets, tolerations, node
   selector, node affinity and security context.
4. Copies the backup into place.
5. Scales the Deployment back to 1 and restores the CronJob's previous
   `suspend` setting.

If the Job never starts (for example, it cannot be scheduled or the image
cannot be pulled), nothing has been moved, so the script scales the Deployment
back up. If the copy fails after it has started, the Deployment stays at 0.

Do not run `helm upgrade` while a restore is in progress, because it scales the
Deployment back to 1.

## PostgreSQL backend

`runtime.backend: postgres` (default off) runs the server on an external
PostgreSQL database. Uploaded files stay on the data PVC (see Node drains), and realtime, presence
and rate limits are in-process, so `replicaCount` must stay 1. The image is
`runtime.postgres.image` (12.8.0-pg.3), not `image.*`.

Prepare the database first: the `relaycast_owner` and `relaycast_runtime` roles
and schema `public`, as in `docs/self-host-postgres.md` in AgentWorkforce/relaycast.
Then add two keys to `existingSecret`, next to the existing ones:

| Key (value) | Content | Mounted into |
| --- | --- | --- |
| `database-owner-url` (`secretKeys.databaseOwnerUrl`) | `postgres://relaycast_owner:<pw>@<host>:5432/<db>?sslmode=verify-full` | migration Job only |
| `database-runtime-url` (`secretKeys.databaseRuntimeUrl`) | `postgres://relaycast_runtime:<pw>@<host>:5432/<db>?sslmode=verify-full` | server only |

The password must be URL-encoded, and `sslmode=verify-full` is the only accepted
query parameter.

```yaml
runtime:
  backend: postgres
postgresCa:
  enabled: true
  configMap: postgres-ca-bundle   # or secret: <name>; key defaults to ca.crt
```

`postgresCa` mounts the CA that signs the database certificate at
`/etc/postgres-ca/ca.crt` and sets `NODE_EXTRA_CA_CERTS`. It is required on this
backend and refused on the others.

A plain Job (`<release>-relaycast-migrate-<hash>`, no Helm hook) runs `migrate`
as the owner; its name hashes the rendered pod template, so a new image or
setting runs a new Job. The server's `wait-for-migrations` init container runs
`verify-db` as the runtime role and holds the server until the database is
migrated for this image; the server then checks identity and the ledger again
before it listens. Install with `--wait --wait-for-jobs`, or wait for the Job
yourself. Exit codes are `64` (configuration), `65` (identity) and `1` (failure):
the Job does not retry 64 or 65, and a server or init container that exits with
one needs an operator fix.

The chart refuses a half-configured backend at render: no CA, a missing or
shared URL key, `replicaCount` other than 1, `backup.enabled` (the backup CronJob
is SQLite-only, so back up the database with its own tooling),
`retention.messageTtlDays`, or chart-managed database variables in `extraEnv`.

### Database failover

With an image from relaycast main 810f48ce or later (relaycast#667), the server
recovers from a database failover without a restart. Turn the chart side on
with it:

- `healthProbes: split`. Startup and liveness use `/health/live`, which fails
  only after 90 s without a successful database probe, so the pod is restarted
  only if it did not recover. Readiness uses `/health/ready`, which fails while
  the database does not answer within 2 s, so the Service stops routing to the
  pod during the failover. Keep `legacy` (every probe on `/health`) for older
  images: they answer 404 on the new paths and never become ready.
- `runtime.postgres.tcpKeepalive` (on by default on this backend) sets the
  `net.ipv4.tcp_keepalive_intvl=5` and `tcp_keepalive_probes=3` sysctls on the
  pod, so a half-open connection to the old primary is detected in about 15 s.
  They are namespaced safe sysctls from Kubernetes 1.29 and are not rendered on
  older clusters. Sysctls of the same name in `podSecurityContext` win.

The `wait-for-migrations` init container and the migration Jobs start Node
directly, so the chart sets `NODE_OPTIONS=--max-old-space-size` to 75 % of
`resources.limits.memory` for them (the image entrypoint does the same for the
server, relaycast#668). An operator `NODE_OPTIONS` in `extraEnv` wins.

### Node drains

Uploaded files keep the server on its `ReadWriteOnce` data claim, and an EBS (or
other zonal) volume attaches only in its own availability zone. The Deployment
uses `Recreate`, so a drain stops the pod, the volume detaches, and the pod
starts again on another node of that zone. Keep it short:

- Run at least two schedulable nodes in the volume's zone. With one, the pod
  stays Pending until a node in that zone exists again.
- Set `persistence.zone` to that zone so the scheduler only considers nodes
  that can attach the volume. Find it with
  `kubectl get pv "$(kubectl get pvc <release>-relaycast-data -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.nodeAffinity}'`
  and check the nodes with `kubectl get nodes -L topology.kubernetes.io/zone`.
- There is no PodDisruptionBudget: with one replica, any budget that protects
  the pod blocks every drain.

Losing the zone is an outage until the zone returns or the volume is restored
from a snapshot in another zone. The S3 file store that removes the claim on
this backend is planned for a later release.

Moving an existing SQLite release to this backend does not migrate its data.

## Self-host analytics

Relaycast analytics is off by default. To send typed events to your installation's
telemetry collector, select a digest for a Node Relaycast image with collector
support and set `analytics.enabled`. The collector needs a `relaycast` producer
registration with the same deployment ID and a dedicated credential.

```yaml
analytics:
  enabled: true
  collectorUrl: https://telemetry-collector.agent-relay.svc.cluster.local:8443/v1/events
  deploymentId: installation_1
  existingSecret: relaycast-analytics-token
  tokenKey: token
  caConfigMap: telemetry-collector-ca
  caKey: ca.crt
```

The chart mounts the token and CA read-only in the application container.
Authorize its analytics producer pod label on the collector's ingress policy
and allow the collector endpoint in any existing Relaycast egress policy.
PostgreSQL keeps its explicit database CA and its migration Job and init
container keep their existing CA environment. The durable-actors runtime
does not expose this Node adapter. An enabled binding cannot override its
TLS settings through `extraEnv`.

## Upgrades and rollback

`0.1.0` pinned Relaycast `8.0.0`, which allows anonymous workspace creation with
no way to turn it off. Treat any `0.1.0` install as private test only. Upgrade
to `0.2.0` as follows:

```bash
kubectl -n relaycast create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"
helm upgrade relaycast agentworkforce/relaycast -n relaycast --version 0.2.0 \
  --set baseUrl=https://relay.example.com --set existingSecret=relaycast-secrets
```

The data PVC (`relaycast-data` for a release named `relaycast`) is reused. Existing workspaces, keys,
agents and history carry over, and the new engine migrates the schema on boot.

**`helm rollback` to `0.1.0` is not supported once `0.2.0` has started.** The
`8.0.0` engine cannot read the migrated schema (`no such column: "plan"`), so
every authenticated request returns `500` while `/health` still returns `200`.
To go back, restore a backup taken before the upgrade into a `0.1.0` release.
Rolling forward restores service with the data intact. Use `helm upgrade` with
your `0.2.0` values, not `helm rollback` to the `0.2.0` revision: when backups
are enabled, the rollback cannot re-adopt the retained backup PVC (`spec is
immutable`), but an upgrade can.

Releases within the 12.x line apply forward-only migrations. Take a backup
before every upgrade.

## Composition

Install add-ons separately and point them at the core through their documented
URLs and credentials. Relayflows is needed only for durable workflow execution,
and the Sessions Pipeline only for session capture and evaluation. Neither is on Relaycast's
availability path.
