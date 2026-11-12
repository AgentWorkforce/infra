# Relaycast: Postgres backend to durable-actors (upgrade path)

Status: design, 2026-11-12. Implementation is tracked in the PRs listed under
"Code changes".

Decision (Khaliq, 2026-11-12): self-hosted installs on Relaycast
`runtime.backend: postgres` move to `runtime.backend: durable-actors`
([self-hosted-durable-actors.md](self-hosted-durable-actors.md)) instead of us
fixing the Postgres engine, which deadlocks under fan-out (relaycast#651: 100
agents, 5 channels, 20 posts/s gives 7 of 837 OK and 1012 deadlocks). The
migration is **always a full copy and never drops data**: it refuses rather
than lose anything. Downtime has no target; safety comes first. Before this
doc, actor mode was fresh-install only.

Scope: one install moves its Relaycast (the umbrella's `relaycast` component)
from the Postgres runtime (`values-eks-rds-native.yaml`) to the actor runtime
(`values-eks-actors.yaml` layered on it), with the same chart version before
and after.

## Facts that shape the design

1. **Engine schema is shared.** Both backends run the same engine and the same
   46 tables (drizzle `schema.pg.ts`; the actor's SQLite migrations are
   generated from the same source). The copy is table by table with ids
   kept, not a translation. One actor holds exactly one workspace, so the copy
   is per workspace.
2. **Workspace ids are portable.** Every backend mints 64-bit snowflake
   workspace ids, which is what `ar_` credentials and the actor gateway need
   (`isArWorkspaceId`). The gateway routes `/internal/workspaces/:id/...` to the
   actor for that id, so an import can target the existing id. **The workspace
   id is preserved**, and every relay-control row keyed by
   `relaycast_workspace_id` stays valid.
3. **Legacy credentials cannot route on actors.** `values-eks-rds-native.yaml`
   runs `credentials.format: legacy` (chart default). The actor gateway routes
   only by the workspace id and keyring-signed tag inside an `ar_` credential,
   so a legacy `rk_live_`/agent/node/observer/webhook credential is refused
   before any actor sees it. The engine already has the cure, on Postgres:
   with a keyring, `credentials.format: ar` (legacy credentials keep verifying
   during `RELAYCAST_LEGACY_CREDENTIAL_GRACE_SECONDS`), `POST
   /v1/credentials/upgrade` (TS, Rust and Swift SDKs implement it) and
   `POST /internal/workspaces/:id/api-key` (server-minted `ar_ws_` rotation)
   swap a principal's hash to an `ar_` one in place. **Credentials are
   upgraded on Postgres before cutover, and their `ar_` hashes are then copied
   verbatim.** No upgraded holder re-registers.
4. **relay-control holds Relaycast credentials.** The workspace key
   (`workspaces.relaycast_api_key_ciphertext`) and agent tokens in
   `selfhost_hosted_relay_participants` (0012), `capy_bindings` (0045) and the
   person/desktop identities (0011, 0020). It must upgrade each one it holds
   (the "re-key" op below).
5. **Files.** On Postgres the bytes are on the relaycast PVC
   (`RELAYCAST_FILE_DIR`); on EKS actors they are in S3 (`fileStore: s3`) under
   the store's key layout. The metadata is in `files`/`message_attachments`.
6. **Same public surface.** The actor gateway keeps the Postgres Deployment's
   name and selector, so the Service, Ingress and `cast.<domain>` URL do not
   change for relay-control, the webapp, desktops or agents.
7. **Load.** Hosted prod writes about 5.6k messages/day. A first-week
   self-hosted install holds close to none, but the tool is sized and tested
   for at least 1M messages per workspace.

## What moves

| State (engine tables) | Handling |
| --- | --- |
| `workspaces` (id, name, settings, key hash/generation, expiry) | copied, same id; key hash is the `ar_ws_` one from phase 1 |
| `agents`, `agent_recovery_credentials`, `agent_identity_audit`, `nodes`, `node_providers`, `agent_node_bindings`, `observer_tokens` | copied, same ids; token hashes as upgraded in phase 1 |
| `channels`, `channel_members` | copied |
| `messages` (ids, `seq`, timestamps, threads), `message_sessions`, `message_logs`, `reactions`, `read_receipts` | copied verbatim: ordering is the stored `seq`, not re-derived |
| `dm_conversations`, `dm_participants`, `dm_conversation_reservations`, `direct_dm_idempotency` | copied |
| `files`, `message_attachments` + bytes | rows copied; bytes copied PVC to S3 under the same object keys, sha256 checked per object |
| `webhooks`, `event_subscriptions`, `webhook_deliveries`, `deliveries`, `pending_events`, `triggers`, `actions`, `action_invocations` | copied; webhook tokens upgraded in phase 1 |
| `directory_*`, `routing_*`, `certifications`, `session_events`, `workspace_events`, `usage_records`, `maintenance_cursors` | copied |
| `credential_upgrades` | **not copied**: the legacy hashes it maps cannot route on actors (fact 3) |
| `workspace_create_idempotency`, `file_cleanup_queue` | copied (small; keeps retries and cleanup correct) |
| Actor adapter tables (kv, outbox, sockets, credential tag) | created fresh by the actor; nothing to copy |
| Rate limits, presence, live sockets | ephemeral, rebuilt on reconnect |
| Analytics / telemetry going forward | **gap**: actor collector is a no-op (relaycast#648) |

Any table the tool does not know (a newer engine schema) fails preflight: the
tool's table list is pinned to the engine schema version, and source and
target must report the same migration head.

## Phases

### Phase 0: preflight (read-only, refuses on failure)

The upgrader (`--migrate-relaycast-to-actors`, default off) runs a preflight Job
(`relaycast-migrate preflight`, image = the release's relaycast self-host
image, mounting the existing `RELAYCAST_DATABASE_URL` Secret; nothing echoed)
and refuses unless all hold:

- the release's relaycast is `runtime.backend: postgres`, `--profile
  eks-rds-native`, `--apply` and `--db-instance` given;
- the target chart ships `values-eks-actors.yaml` and it renders layered on
  the install's values; durable-actors control plane healthy; S3 bucket and
  IAM reachable (deployer and gateway ServiceAccounts);
- the Relaycast Secret holds the keys `credential-keyring` and
  `workspace-bootstrap-secret` (names checked, values never read into logs);
- the Postgres engine migration head equals the actor bundle's engine
  migration head (same engine version on both sides);
- PVC file bytes present for every `files` row (missing object = refuse);
- prints per-workspace counts for every table, which are the export manifest's
  expected counts.

### Phase 1: credential upgrade on Postgres (online, reversible)

1. `helm upgrade` the **Postgres** release with `credentials.format: ar`,
   `authority: self`, the keyring, and a long legacy grace. Legacy credentials
   keep working, new ones are `ar_`.
2. relay-control `relaycast rekey` (new): for each bound workspace, rotate the
   workspace key through `POST /internal/workspaces/:id/api-key` (server-minted
   `ar_ws_`, grace for the old one) and store it; upgrade every agent token it
   holds through `POST /v1/credentials/upgrade` and store the results. Old
   ciphertexts go to a backup table first (`rekey --undo`).
3. Desktops and SDK agents upgrade their own tokens (SDK `upgradeCredential`).
   The preflight reports **principals still on legacy hashes** per kind (a
   principal whose current hash is not an `ar_` hash). The operator waits
   until this is zero, or passes `--reregister-legacy` to accept that those
   holders re-register after cutover (their rows and data are still copied; only
   the credential is reissued). Without either, the migration refuses.

### Phase 2: snapshot and quiesce

1. RDS snapshot (the upgrader's existing step) and a `pg_dump -Fc` of the
   Relaycast database alone into the operator state dir.
2. Scale relay-control's API and Relaycast to 0. From here messaging is down.
   Writes are impossible, so the export is consistent.

### Phase 3: export

`relaycast-migrate export` (Job, same image) reads each workspace in one
`REPEATABLE READ` transaction, in FK order, and writes NDJSON per table plus a
manifest: row count and a checksum per table (sha256 over rows serialized
canonically and sorted by primary key; timestamps as epoch ms; JSON columns
canonicalized) and the engine migration head. Output goes to a PVC (or S3
prefix) owned by the Job. It contains credential **hashes**, never plaintext,
and is deleted after verification unless `--keep-export`.

### Phase 4: cutover

`helm upgrade` with `values-eks-actors.yaml` layered after the install's values
(other components stay on), same chart version. The deployer Job registers the
relaycast actor project; the gateway takes the Service. The Postgres Deployment
is gone, and the Postgres database is untouched.

### Phase 5: import

`relaycast-migrate import` streams each workspace's NDJSON to
`POST /internal/workspaces/:id/import` (new; internal secret; chunked) on the
gateway, which forwards to that workspace's actor:

- refused unless the actor's workspace does not exist yet, or holds an
  unfinished import with the same `run_id` (resume after a failed chunk);
- each chunk is one table slice inserted with original ids inside the actor's
  transaction, idempotent by `(run_id, table, chunk)`;
- `finish` checks referential integrity, rebuilds derived state (`seq`
  counters, unread counts), recomputes the per-table counts and checksums from
  actor SQLite and returns them; the workspace is not served (public routes
  answer 503) until `finish` succeeds.

File bytes: `relaycast-migrate files` copies each object from the PVC to the S3
store under the key its row names and checks sha256 after upload.

### Phase 6: verify (gates "done")

- import `finish` counts and checksums equal the export manifest, per table,
  per workspace; any difference fails;
- every file object present in S3 with matching sha256;
- relay-control's stored workspace key authenticates on actors; one stored
  agent token per relay-control table authenticates;
- synthetic round trip in a dedicated `migration-check-<run>` channel: two
  throwaway agents register, post, DM, upload/fetch 1 KiB, receive over
  WebSocket; a read of the newest pre-migration message by id returns it with
  the same `seq`; then the check agents and channel are deleted;
- relay-control `/healthz` and its Relaycast probe green after scale-up.

## Rollback

Postgres is never written after phase 2, so it remains the pre-cutover state.

- Before phase 4: scale back up. Nothing changed but phase 1, which is safe to
  keep (legacy still accepted); `rekey --undo` restores relay-control's old
  ciphertexts if wanted.
- After phase 4: `helm rollback` to the phase 1 revision (printed), scale
  relay-control up. The `ar_` credentials stay valid on Postgres (phase 1 put
  their hashes there). Delete the half-imported actor workspaces
  (`DELETE /internal/workspaces/:id`) before retrying.
- After go-live on actors: messages written on actors are not on Postgres. A
  rollback then needs the reverse copy (same tool, actor export into Postgres),
  which is out of scope for v1; the upgrader refuses rollback past go-live
  without `--accept-loss`. Restore of the RDS snapshot covers relay-control's
  database.

## Downtime

From phase 2 to the end of phase 6. With no data it is a few minutes (deployer
Job, first actor activation, verify); otherwise export and import dominate.
They are measured on Kind and the sandbox, and the proof reports the rate.
There is no target (decision above); the upgrader prints the measured
estimate from the preflight counts before asking to proceed.

## Upgrader integration

- `scripts/selfhost/agent-relay-upgrade.sh --migrate-relaycast-to-actors`, and
  `selfhost-upgrade.yml` input `migrate_relaycast_to_actors` (default false).
  Plan mode runs only phase 0 and prints the plan; `--apply` runs phases 1-6
  with confirmation. Phase 1's legacy-principal wait can be split
  (`--phase credentials` now, `--phase cutover` later).
- On any failure it stops, prints the rollback commands for the phase it
  reached, and the snapshot id.
- No secret on argv or in logs: Jobs mount existing Secrets; the tool prints
  counts and checksums only.

## Code changes

| Repo | Change |
| --- | --- |
| relaycast | `relaycast-migrate` CLI in the self-host image (`preflight`, `export`, `files`, `import`, `verify`); actor internal route `POST /internal/workspaces/:id/import` (+ `finish`, `status`) with the not-served-until-finished gate; gateway pass-through; conformance tests copying a seeded Postgres workspace into an actor and comparing checksums. |
| relay-control | `relaycast rekey` (+ `--undo`), backup table migration, tests. |
| infra | this doc; relaycast chart migration Jobs (`migration.*`, off by default); upgrader flag and workflow input; Kind proof (`ci/agent-relay`); runbook in `docs/operations`. |

## Proof

- Kind: Postgres-profile install, seeded (several workspaces, 100 agents,
  channels and memberships, threads, DMs, reactions, files, webhooks, 100k+
  messages), phase 1 with SDK upgrades plus some deliberately legacy agents,
  migrate to `kind-durable-actors-values.yaml` (devRuntime), phase 6 gates, a
  forced mid-import failure and resume, and a rollback drill.
- AWS sandbox (805532413586), in our own namespace, coordinated with
  infra-environments and relaycast-actors-bench: the same flow on RDS + S3, and
  messaging load on actors after migration.

## Known gaps

- Analytics: the actor runtime's telemetry/analytics collector is a no-op
  (relaycast#648). Relaycast usage analytics stop at cutover until it is
  fixed. Historical `usage_records` are copied.
- Rollback after go-live loses actor-side writes (reverse copy not in v1).
- Holders still on legacy credentials at cutover re-register once (only with
  `--reregister-legacy`).
