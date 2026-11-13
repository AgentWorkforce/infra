# Runbook: move an existing install's Relaycast from PostgreSQL to durable-actors

Operator procedure for an EKS install (`--profile eks-native` or
`eks-rds-native`, whichever it already uses) whose Relaycast runs on
`runtime.backend: postgres` against RDS. It moves every workspace, with
all its rows and files, under the same ids. Design and rationale:
[relaycast-postgres-to-actors-migration.md](../relaycast-postgres-to-actors-migration.md).
Keep install-specific values (account, hosts, windows) out of this repo.

> **Status (2026-11-13): not recommended for production self-hosts yet.** Keep
> production installs on `runtime.backend: postgres`. In the tuned comparison,
> durable-actors delivery was about 100x slower (p50 3.5 s vs 36 ms), and
> recovery from an RDS failover took about 4.5 min (vs under 45 s on
> PostgreSQL with relaycast #667). The move waits for sub-workspace sharding
> and latency work. The tooling and this procedure stay current for that
> later move.

Two upgrader runs, on the release the install already runs (the chart version
does not change). Each takes an RDS snapshot first and refuses on any failed
precondition. Plan mode (no `--apply`) only checks and prints.

| Run | Downtime | What it does |
| --- | --- | --- |
| `--relaycast-actors credentials` | none | Relaycast issues `ar_` credentials; relay-control re-keys what it stores |
| `--relaycast-actors cutover` | yes (phases 2-6) | preflight, quiesce, export, cutover, files, import, verify, go-live |

## 0. Before the window

- [ ] The install runs a release that ships the migration: relaycast chart
      0.3.10+ (agent-relay 0.6.59+), a Relaycast self-host image with
      `migration-preflight` / `export-for-actors` (relaycast #653), actors
      gateway and deployer images with relaycast #653, #655 and #656, and a
      relay-control image with `relaycast-rekey` (relay-control #122).
- [ ] Every image the cutover will run is mirrored into the install's
      registry by digest (the plan refuses otherwise).
- [ ] AWS: one S3 bucket for actor state and Relaycast files; an actor node
      group labelled `durable-actors/role=actor-host`, tainted
      `durable-actors/actor-host=true:NoSchedule`, in one zone (=
      `durable-actors.placement.zone`); Pod Identity roles bound to
      `<release>-durable-actors` (control plane, pool manager),
      `relaycast-actors-deploy` (deployer) and `relaycast` (gateway, migration
      Jobs). Policies: `scripts/selfhost/eks-actors-sandbox.sh`.
- [ ] Durable-actors database on RDS: `actors-credentials/postgres-url` uses
      the RDS DNS name and `?sslmode=require`; the `rds-ca` ConfigMap exists
      (verified TLS through `SSL_CERT_FILE`, infra #274). Keep
      `rds.force_ssl=1`.
- [ ] `--actors-values` file: your overrides for the actors profile (bucket,
      `publicUrl`, zone, mirrored image repositories and digests). The
      upgrader pins the Relaycast Secret, keyring, bootstrap mapping,
      `retainForMigration` and analytics-off itself. Restate the install's
  `relaycast.baseUrl` there: the actors profile's placeholder replaces it, and
  the render fails without it.
- [ ] The Relaycast Secret has a `file-signing-secret` key with the same bytes
      as the actor env's `RELAYCAST_FILE_SIGNING_SECRET`. A PostgreSQL install
      never needed it. Without it the gateway can't start, and the plan
      refuses with a message about the actor env Secret.
- [ ] `STATE_DIR` is the same directory for both runs (the workflow input
      `state-dir`), owned by the operator, 0700.
- [ ] relay-control's encryption key will not change until the re-key backups
      are purged.

## 1. Credentials (any time before the window)

```sh
scripts/selfhost/agent-relay-upgrade.sh --version <current> --registry <ecr> \
  --profile <your profile> --values <values>... --db-instance <rds id> \
  --relaycast-actors credentials            # plan; then add --apply
```

It switches Relaycast to `credentials.format: ar` (legacy credentials keep
working through the grace period), records the switch time, and runs
`relaycast-rekey` in relay-control, recording its run id under `STATE_DIR`.
Add the printed `relaycast.credentials` block to your values.

Then let desktops and SDK agents upgrade their own tokens on use. The cutover's
preflight lists principals still on legacy credentials and refuses while any
remain, unless you pass `--reregister-legacy` (those holders register again
after the move; their data still moves).

## 2. Cutover (the window)

```sh
scripts/selfhost/agent-relay-upgrade.sh --version <current> --registry <ecr> \
  --profile <your profile> --values <values>... --db-instance <rds id> \
  --relaycast-actors cutover --actors-values <actors overrides>   # plan; then --apply
```

Order, each step failing the run:

1. preflight Job (counts, missing files, legacy principals, export capacity);
2. RDS snapshot; relay-control and Relaycast to 0 (pods confirmed gone);
3. export Job (one snapshot, sealed, on the Relaycast data claim);
4. `helm upgrade` with the Relaycast-only actors overlay (relay-control stays at 0);
5. files Job (to S3, sha256 checked), import Job (each workspace verified by
   count and digest, still closed: 503);
6. verify Job (a throwaway workspace streams a post over `/v1/ws`), go-live
   recorded, open Job, relay-control back to its replicas.

Measured on a five-workspace rehearsal (101k rows, 27 files, RDS db.r7g.large
Multi-AZ): preflight 8 s, quiesce 2 s, export 19 s, cutover 18 s, files 12 s,
import 96 s, verify 15 s, open 18 s; downtime 180 s. Estimate downtime from the
preflight's counts: about 75 s, plus 0.8 s per 1,000 rows, plus 3 s per
workspace, plus the file copy. Add the RDS snapshot before it (about 3 min for
50 GB). At 1M rows, plan for about 15 minutes.

## 3. Verify after go-live

- the upgrader's last lines: every workspace imported, verified and open;
- a post and a DM from an existing desktop or agent, read back; a realtime
  event arrives;
- an upload and download of a file;
- relay-control `/healthz` and its Relaycast probe green.

## 4. If something fails

| Where | What to do |
| --- | --- |
| before the helm upgrade | scale relay-control and Relaycast back up; nothing changed but credentials (safe to keep) |
| after the helm upgrade, before go-live | either rerun `cutover` (it resumes the recorded run: files, import, verify, open), or `helm rollback <release> <printed revision>`; nothing was served from the actors, so nothing is lost |
| a new `cutover` after such a rollback | the new run's import fails with `409 import_run_mismatch` while the old run still owns the actors. First empty each workspace's actor with the old run id: `relaycast-migrate abort --dir /data/migration/<old run> --gateway <url> --workspace <id>` (import Job image; about 8 s per workspace) |
| after go-live is recorded | forward only: rerun `cutover` to open the remaining workspaces; do not roll back (opened workspaces may have taken writes PostgreSQL never sees) |
| relay-control re-key | `relaycast-rekey --undo <run id>` in the relay-control pod (run ids under `STATE_DIR`) |

The RDS snapshot from step 2 and the PostgreSQL database stay untouched until
clean-up.

## 5. Clean up (after go-live is confirmed)

1. Put the pinned values the upgrader printed and your `--actors-values` into
   your values.
2. `relaycast-rekey --purge <run id> --confirm` in relay-control.
3. Delete `/data/migration/<run>` on the Relaycast data claim, then set
   `persistence.retainForMigration: false` once files are confirmed in S3.
4. Drop the Relaycast PostgreSQL database after your retention period.

Known gaps: Relaycast analytics stop at the cutover (relaycast #648); blob
deletions from actors still go through Relaycast's public URL.
