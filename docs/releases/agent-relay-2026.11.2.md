# Agent Relay 2026.11.2

A PostgreSQL robustness release. Relaycast stays on its PostgreSQL backend:
it recovers from a database failover without a restart, and it no longer
deadlocks, races or overloads under its known failure patterns. Upgrade with
the usual release upgrader (`scripts/selfhost/agent-relay-upgrade.sh`, plan
first, then `--apply`). The plan now also decides how the Sessions index
migration runs on your database (below).

## What changes

- **Relaycast 12.8.0-pg.3** (`relaycast-self-host@sha256:cc2a79f02d39978fa04322b5a45497737ff137bc2a5db5615c7eee690030de83`,
  relaycast `810f48ce`):
  - relaycast #657: a deadlock between concurrent writers is fixed;
  - relaycast #663: a race that could store a duplicate is closed;
  - relaycast #664: node heartbeats no longer recompute capabilities on every
    beat, which cuts database load;
  - relaycast #667: the connection pool recovers from an RDS failover without a
    pod restart (under 45 s in the failover test);
  - relaycast #668: the V8 heap is sized from the container's memory limit.
- **Relaycast chart 0.3.12** (infra #300):
  - `healthProbes: split` puts startup and liveness on `/health/live` and
    readiness on `/health/ready`. It needs an image with relaycast #667, such
    as 12.8.0-pg.3. The default, `legacy`, keeps `/health`.
  - TCP keepalive on the PostgreSQL backend finds a half-open connection to a
    failed-over primary in about 15 s.
  - The init container and the migration Jobs get a heap size from their
    memory limit.
  - `persistence.zone` pins Relaycast to its volume's zone.
- **Sessions**:
  - migration 20261105058000 adds the indexes the operator per-user erase
    needs;
  - migration 20261105059000 lets a GCS install publish canonical copies (the
    publication RPCs accepted only `s3`).

## Upgrading: the Sessions index step

Four Sessions migrations (20261105044020, 044040, 047000 and 058000) adopt an
index that was prebuilt with `CREATE INDEX CONCURRENTLY`, or build a missing
one themselves. They build only on an empty table. On a populated table they
refuse (SQLSTATE 55000) unless the migrate Job has
`HOOPDB_ALLOW_BLOCKING_INDEX_BUILD=true`, which takes a blocking build: a SHARE
lock that lets reads continue but makes writes to that table wait.

The upgrader decides this for you. In plan mode and in `--apply`, step 2a
starts one read-only pod, cloned from your deployed HoopDb migrate Job (same
image, database Secret, CA and ServiceAccount, without init containers), and
deletes it afterwards. The pod reads the migration ledger and every pending
step's indexes, and the row count of each table that would get a blocking
build. Then:

| What the census finds | What the upgrade does |
| --- | --- |
| every step applied, or each index prebuilt or on an empty table | nothing extra; the migration adopts or builds each index |
| absent indexes on populated tables, with at most `AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS` rows to index (default 1,000,000) | this upgrade alone sets `sessions-pipeline.worker.migrations.allowBlockingIndexBuild: true` (the migrate Job only; the next upgrade drops it). The plan lists each index, its table's rows and the expected lock |
| more rows than that | refuses before anything changes. Prebuild the listed indexes `CONCURRENTLY` with the packet it names (for 058000, `docs/packets/operator-user-erase-index-packet.md` in the Sessions repository), then re-run: the migration adopts them without locking |
| an INVALID, still-building or drifted index | refuses. Follow "Failed or cancelled builds" in that packet, then re-run |
| a census that can't read the database (for example row-level security on the owner role) | refuses; nothing was changed |

"Rows to index" counts each absent index's table once per index. On
PostgreSQL 17, 058000 built its sixteen indexes over 2.64 million rows to index
in 2.5 s on a 24-core host. The plan's estimate assumes a 2-vCPU database is
about four times slower (250,000 rows/s, `AGENT_RELAY_INDEX_BUILD_ROWS_PER_SECOND`).
At the default limit, the lock lasts a few seconds.

Leave `allowBlockingIndexBuild` out of your values: the upgrader refuses a
values file that sets it.

`helm rollback` to the revision such an upgrade made restores that revision's
values, the opt-in included. If you roll back, then upgrade again with the
upgrader: its fresh census sets the opt-in, or drops it, for the new run.

## Durable-actors for Relaycast: available, opt-in, not recommended yet

The move of an existing Relaycast from PostgreSQL to TerseAI durable-actors
ships as tooling: the `--relaycast-actors credentials|cutover` upgrader phases
and the migration Jobs. It is not recommended for production yet. In the tuned
comparison, delivery was about 100x slower (p50 3.5 s vs 36 ms), and recovery
from an RDS failover took about 4.5 min (vs under 45 s on PostgreSQL with
relaycast #667). It waits for sub-workspace sharding and latency work. No
ordinary `helm upgrade` switches the backend.

When you do run it, follow the runbook,
[relaycast-actors-upgrade-runbook.md](../operations/relaycast-actors-upgrade-runbook.md);
the design is in
[relaycast-postgres-to-actors-migration.md](../relaycast-postgres-to-actors-migration.md).
Its gates, for any candidate you'd use for the move:

1. the tuned AWS actor soak is clean, including actor-host kill and node-drain
   recovery, with no lost, duplicated or reordered accepted messages;
2. the gateway and deployer digests were built from the reviewed Relaycast
   source recorded in the customer image manifest;
3. the pinned relay-control image contains the reviewed `relaycast-rekey`
   command and its database migration.

The tuned runtime target (`values-eks-actors.yaml`):
- Relaycast files on S3, with no Relaycast PVC;
- three zone-spread gateways with a `maxUnavailable: 1` PDB;
- 1024 MiB actor hosts, three warm, `maxStarting: 8`;
- a single controller at 1 CPU / 1-2 GiB.

Multiple controllers need Redis. Multi-zone actor placement needs a separately
qualified TerseAI runtime.

No live customer change is authorized by these source and chart changes.
