# Relaycast: Postgres backend to durable-actors (upgrade path)

Status: design, 2026-11-12, kept in step with the implementation PRs listed
under "Code changes".

Decision (Khaliq, 2026-11-12): self-hosted installs on Relaycast
`runtime.backend: postgres` move to `runtime.backend: durable-actors`
([self-hosted-durable-actors.md](self-hosted-durable-actors.md)) instead of us
fixing the Postgres engine, which deadlocks under fan-out (relaycast#651: 100
agents, 5 channels, 20 posts/s gives 7 of 837 OK and 1012 deadlocks). The
migration is **always a full copy and never drops data**: it refuses rather
than lose anything. Downtime has no target; safety comes first.

Scope: one install moves its Relaycast (the umbrella's `relaycast` component)
from the Postgres runtime (`values-eks-rds-native.yaml`) to the actor runtime,
on the chart version already deployed. Nothing else in the suite changes:
the upgrader layers only the `relaycast` and `durable-actors` parts of
`values-eks-actors.yaml` (the profile as a whole turns the rest of the suite
off and moves Relayfile).

The release must first deploy a PostgreSQL image containing the export side of
the protocol. The EKS RDS-native profile pins `12.8.0-pg.2`, source
`a63961bd` (relaycast #653 plus #657), digest
`sha256:1307bd845031a7466e65ebaf08bc8b826e2837d90f58c9b5a6a1d673c62dad93`,
from attested publish run 43351584271. The upgrader deliberately requires the
target chart version to be live before either migration phase.

## Facts that shape the design

1. **Engine schema is shared.** Both backends run the same engine and the same
   tables (drizzle `schema.pg.ts`; the actor's SQLite migrations come from the
   same source). The copy is table by table with ids and rowids kept. One
   actor holds one workspace, so the copy is per workspace.
2. **Workspace ids are portable.** Every backend mints 64-bit snowflake ids,
   which `ar_` credentials and the actor gateway need. The gateway routes
   `/internal/workspaces/:id/...` to that id's actor, so an import targets the
   existing id and every relay-control row keyed by `relaycast_workspace_id`
   stays valid.
3. **Legacy credentials cannot route on actors.** The actor gateway routes
   only by the workspace id and keyring-signed tag inside an `ar_` credential.
   Credentials are therefore upgraded on Postgres first (phase 1), and their
   `ar_` hashes copied verbatim. The keyring must be the same Secret key on
   both releases, or the routing tags differ.
4. **relay-control holds Relaycast credentials**: the workspace key
   (`workspaces.relaycast_api_key_ciphertext`), agent tokens in
   `person_identities`, `hosted_relay_participants`, `desktop_relay_identities`,
   `amp_bindings`, `factory_bindings` and `capy_bindings`, and a webhook token
   in `events_shims`. `relaycast-rekey` (relay-control#122) upgrades each.
5. **Files.** On Postgres the bytes are on the relaycast data claim
   (`/data/relaycast-files`); on EKS actors they are in S3. The data claim is
   kept rendered through the move (`persistence.retainForMigration`, set by the
   upgrader), so it survives the cutover and a rollback.
6. **Same public surface.** The actor gateway keeps the Relaycast Service, so
   `cast.<domain>` does not change for relay-control, the webapp, desktops or
   agents.
7. **Actors reach only public addresses and the control plane** (sandbox
   NetworkPolicy). Two consequences, both fixed: the gateway dials actor
   sockets through the in-cluster control plane
   (`runtime.durableActors.socketOrigin: controlPlane`, relaycast#655), and
   upload completion uses the size the gateway recorded after its verified PUT
   instead of the actor fetching the public URL (relaycast#656).

## What moves

| State (engine tables) | Handling |
| --- | --- |
| `workspaces` (id, name, settings, key hash/generation, expiry) | copied, same id; key hash is the `ar_ws_` one from phase 1 |
| `agents`, `agent_recovery_credentials`, `agent_identity_audit`, `nodes`, `node_providers`, `agent_node_bindings`, `observer_tokens` | copied, same ids; token hashes as upgraded in phase 1 |
| `channels`, `channel_members` | copied |
| `messages` (ids, `seq`, timestamps, threads), `message_sessions`, `message_logs`, `reactions`, `read_receipts` | copied verbatim, rowids kept (ordering is the stored data) |
| `dm_conversations`, `dm_participants`, `dm_conversation_reservations`, `direct_dm_idempotency` | copied |
| `files`, `message_attachments` + bytes | rows copied; bytes copied claim to S3 under the same keys, sha256 checked on read-back |
| `webhooks`, `event_subscriptions` (signing secrets and headers), `webhook_deliveries`, `deliveries`, `pending_events`, `triggers`, `actions`, `action_invocations` | copied |
| `directory_*`, `routing_*`, `certifications`, `session_events`, `workspace_events`, `usage_records`, `workspace_create_idempotency`, `file_cleanup_queue`, a2a tables | copied |
| Search indexes (messages, mentions, directory agents and skills) | rebuilt as rows land: their triggers stay live during the import |
| `credential_upgrades` | **not copied**: legacy hashes cannot route on actors |
| `maintenance_cursors` | **not copied**: deployment-wide maintenance state; the actor keeps its own |
| Actor adapter state (KV, outbox, sockets, credential tag); idempotency records held in the server's KV | not copied: writers are stopped before the export, so nothing is in flight |
| Rate limits, presence, live sockets | ephemeral, rebuilt on reconnect |
| Analytics going forward | **gap**: actor collector is a no-op (relaycast#648); the upgrader turns Relaycast analytics off |

The table plan is derived from the engine schema in foreign-key order and
fails for a table it cannot scope to one workspace. The actor's `begin`
refuses an export whose per-table column lists differ from its own, so both
sides must run the same engine schema.

## Phases

### Phase 1: credentials (online, reversible)

`--relaycast-actors credentials`:

1. `helm upgrade` of the Postgres release with `credentials.format: ar`,
   `authority: self` and the install's keyring key. Legacy credentials keep
   working during the engine's grace period; new ones are `ar_`. The switch
   time is recorded under `STATE_DIR` (a retried phase keeps the first one),
   with relay-control's encryption key id.
2. `relaycast-rekey` in the relay-control pod: rotates each workspace key
   (`POST /internal/workspaces/:id/api-key`, server-minted `ar_ws_`, with a
   grace) and upgrades each agent and webhook token it holds
   (`POST /v1/credentials/upgrade`), under a per-workspace lock, backing up the
   old ciphertexts (`--undo`). Each rekey run id and its report (ids, kinds,
   counts) are recorded under `STATE_DIR` for `--undo` and `--purge`. The old
   workspace key keeps working for at most one hour (engine cap): run it with
   relay-control up so clients refresh.
3. Desktops and SDK agents upgrade their own tokens. The cutover preflight
   reports what is still legacy.

relay-control's encryption key must stay the same (or remain as
`previousKeyId`) until the backups are purged; the cutover refuses otherwise.

### Phase 0: preflight (read-only, a Job on the running pod's node)

`relaycast-engine migration-preflight --ar-since <phase 1 time> --file-dir
/data/relaycast-files --export-dir /data` per workspace: row counts (estimates;
the authoritative counts are taken inside the export snapshot), file objects
missing from the claim, and legacy principals: agents, nodes, observer tokens
and webhooks created before the switch and never upgraded, and a workspace key
neither created nor rotated since. It also checks the claim has room for the
export (free space at least twice the database's size). It fails on any
missing file, on export capacity, and on legacy principals unless the operator
passed `--reregister-legacy` (those holders re-register after the move; their
data still moves).

The upgrader's plan mode (no `--apply`) only checks preconditions and changes
nothing; the preflight Job runs with `--apply`, before anything is stopped.
Preconditions:

- `--profile eks-rds-native`; the deployed chart is the release's chart;
  Relaycast on `runtime.backend: postgres` (or a cutover to resume, below);
- the keyring key present in `relaycast.existingSecret`; credentials already
  `ar` and the phase 1 record present (cutover);
- the Relaycast-only actors overlay renders, removes no running Deployment,
  and keeps the gateway on the same Secret and keyring key;
- **every durable-actors Deployment (control plane, pool manager) mounts a
  `postgres-ca` volume: verified TLS to RDS** (infra#274: the stock image's
  OpenSSL trusts `SSL_CERT_FILE`, a bundle of the system roots plus the RDS CA,
  and `sslmode=require` checks the chain and the hostname; a wrong CA, no CA
  or a hostname mismatch fails at startup);
- every cutover image is a release image or a digest-pinned mirror in the
  install's registry, and with `--apply` each mirrored digest is confirmed in
  the registry before anything stops (pods must start after messaging stops);
- the actor env Secret in the sandbox namespace holds the same bytes as the
  gateway for `RELAYCAST_INTERNAL_SECRET`, `RELAYCAST_FILE_SIGNING_SECRET` and
  `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET` (the Postgres runtime's
  `secretKeys.bootstrapSecret` is mapped to the gateway's
  `secretKeys.workspaceBootstrapSecret`);
- relay-control's encryption key unchanged since phase 1;
- the target release includes relaycast#652 (actor raw reads such as
  `GET /v1/inbox` answered with tuples).

### Phase 2: snapshot and quiesce

RDS snapshot (the upgrader's existing step), then relay-control and Relaycast
to 0 replicas, and the upgrader confirms their pods are gone (it refuses to
export while one remains). From here messaging is down.

### Phase 3: export

`relaycast-engine export-for-actors --out /data/migration/<run> --run-id <run>`
reads every workspace in one `REPEATABLE READ READ ONLY` transaction, in FK
order, into a `manifest.json` (tables, columns, row count and digest per table)
and one NDJSON file per table. Each line is a block of `[rowid, ...values]` rows
in the exact form the actor's SQLite stores, bounded by rows and by bytes so
it fits one import request. Rows carry credential hashes and also subscription
signing secrets and headers, so every line is sealed (AES-256-GCM, key derived
from the internal secret and run id, the line's table and position bound in)
and the export is owner-only (0700 / 0600). The Job mounts only the runtime
database URL and the internal secret.

### Phase 4: cutover

`helm upgrade` with the Relaycast-only actors overlay, your `--actors-values`,
and the pinned values (Secret, keyring, bootstrap mapping,
`retainForMigration`, analytics off), same chart version. relay-control stays
at 0 replicas until go-live.

### Phase 5: files and import

`relaycast-migrate files` copies each completed file from the claim into the
gateway's store, verified by sha256 on read-back (reruns skip identical
objects, re-copy on a content-type difference). `relaycast-migrate import`
streams each workspace's blocks to `POST /internal/workspaces/:id/import`:

- `begin` refuses unless the actor is empty or this run owns it (resume);
- each `chunk` is inserted with original rowids in one actor call, read back
  and digested, idempotent per `(table, seq)`;
- derived triggers (sequence high-water marks, liveness revisions, cleanup
  queues, retention pruning) are suspended; search-index triggers and binding
  checks stay live;
- `finish` runs `PRAGMA foreign_key_check`, compares every table's count and
  digest with the manifest, restores the triggers, and leaves the workspace
  `verified` but still closed (503).

### Phase 6: verify and go live

- `relaycast-migrate verify-realtime`: a throwaway workspace streams a new post
  over `/v1/ws` through the gateway (the actor socket bridge), then is deleted;
- go-live is recorded for the run, then `relaycast-migrate open` makes each
  (already verified) workspace serve;
- relay-control is scaled back up.

A rerun of `--relaycast-actors cutover` after a failure in phase 5 or 6
resumes the run (files, import, verify, open) instead of starting over. Once
go-live is recorded the run only goes forward: a rerun opens the remaining
workspaces, and the rollback hint says not to roll back.

### Phase 7: clean up (after go-live is confirmed)

- Put the pinned values and your `--actors-values` into your values.
- `relaycast-rekey --purge <run id> --confirm` in relay-control.
- Delete the export (`/data/migration/<run>`), then set
  `persistence.retainForMigration: false` once the files are confirmed in S3,
  and drop the Relaycast Postgres database after your retention period. The
  RDS snapshot from phase 2 stays as the last copy.

## Rollback

Postgres is never written after the export, and the actors serve nothing
until go-live, so before go-live is recorded a rollback loses nothing:

- before the helm upgrade: scale relay-control and Relaycast back up;
- after it, before `open`: `helm rollback` to the pre-cutover revision (the
  upgrader prints it). The data claim is unchanged (`retainForMigration`). To
  empty an imported actor, `relaycast-migrate abort` (not `DELETE
  /internal/workspaces`, which a workspace being imported answers with 503);
- relay-control's re-key: `relaycast-rekey --undo <run id>` (needs the same
  encryption key).

Once go-live is recorded (before the first `open`), workspaces may take
writes Postgres never sees: the run is forward-only, a rerun finishes opening,
and a rollback would lose those writes (a reverse copy is out of scope for v1).

## Downtime

From phase 2 to the end of phase 6. With little data it is minutes (deployer
Job, first actor activation, verify); otherwise export and import dominate.
The kind proof moved two workspaces of 4287 rows each in under a minute of
Job time.

## Code changes

| Repo | Change |
| --- | --- |
| relaycast | #653: `migration-preflight` / `export-for-actors` (sealed, owner-only, byte-bounded), actor `importData` (begin/chunk/finish/open/abort/status, replayable), gateway import route, `relaycast-migrate files/import/verify-realtime/open/abort`, an end-to-end test from a real Postgres server into an actor. #652 (merged): actor raw reads. #655: `DURABLE_ACTORS_SOCKET_ORIGIN`. #656: upload completion without actor egress. #654: unordered inbox/DM lists (cosmetic). |
| relay-control | #122: `relaycast-rekey` (+ `--undo`, `--purge`), per-workspace locking, all-or-nothing undo. |
| infra | #274: verified TLS from the control plane and pool manager to RDS with the stock upstream image (CA bundle via `SSL_CERT_FILE`, `postgres-ca` volume); no fork release. |
| infra | this doc; #272: relaycast `migration.*` Jobs, `persistence.retainForMigration`, `runtime.durableActors.socketOrigin`, the upgrader's `--relaycast-actors`, the workflow inputs, offline tests and the kind proof. |

## Known gaps

- Analytics: no actor collector (relaycast#648); Relaycast usage analytics
  stop at cutover. Historical `usage_records` are copied.
- Blob deletions from actor maintenance still go through the public URL
  (follow-up to relaycast#656); deleted files' bytes may linger until then.
- Rollback after go-live loses actor-side writes.
- Holders still on legacy credentials at cutover re-register once (only with
  `--reregister-legacy`).
