# Agent Relay 2026.11.2 (draft)

This release prepares the supported AWS EKS move of Relaycast from PostgreSQL
to TerseAI durable-actors. It does **not** switch an existing installation by
ordinary `helm upgrade`: existing rows, credentials and files move only through
the explicit full-copy workflow.

## Release gates

Do not run the move from a release candidate until all three gates are attached
to that exact candidate:

1. the tuned AWS actor soak is clean, including actor-host kill and node-drain
   recovery, with no lost, duplicated or reordered accepted messages;
2. the gateway and deployer digests were built from the reviewed Relaycast
   source recorded in the customer image manifest; and
3. the pinned relay-control image contains the reviewed `relaycast-rekey`
   command and its database migration.

The earlier as-shipped actor profile is not a qualification receipt: its
256 MiB actor hosts repeatedly failed readiness under the production-shaped soak. The
runtime target below is the tuned profile being qualified for this release.

## Before the move

1. Upgrade normally so Relaycast runs the pinned `12.8.0-pg.2` image. It
   contains `migration-preflight`, `export-for-actors` and the PostgreSQL
   deadlock fix. Confirm the release is Ready before continuing.
2. Provision the actor S3 buckets, actor-host node group, Pod Identity roles,
   RDS role/database, Secrets and public actors origin described in
   [self-hosted-durable-actors.md](../self-hosted-durable-actors.md).
3. Mirror every actor image recorded for `values-eks-actors.yaml` in
   `self-hosted/customer-images.yaml` into the customer registry by digest,
   and provide those mirror references in `--actors-values`. Do not use a
   mutable tag. Actor images are not part of the ordinary PostgreSQL install
   render, so they are not automatically added to its release image overlay.
4. Keep the Relaycast credential keyring and relay-control encryption key
   stable through the move. The credentials phase requires a relay-control
   image containing `relaycast-rekey`.

## Move

Run the tagged self-host upgrade workflow twice with the same protected
`state-dir`:

1. `relaycast-actors: credentials` — switches new credentials to `ar_` and
   rekeys the credentials relay-control stores. This phase is online and
   records the first switch time and every rekey run.
2. `relaycast-actors: cutover` — preflights every workspace and file, stops
   writers, exports one consistent snapshot, installs durable-actors, copies
   file bytes to S3, imports and verifies every workspace while it still
   answers 503, verifies realtime, then records go-live and opens the
   workspaces. A failure before go-live remains rollback-safe; after go-live a
   rerun only completes the forward move.

The detailed refusal and recovery rules are in
[relaycast-postgres-to-actors-migration.md](../relaycast-postgres-to-actors-migration.md).

## Runtime target

- Relaycast file bytes use S3; the Relaycast Deployment and target render have
  no PVC.
- Three stateless gateways have a `maxUnavailable: 1` PDB and hard zone spread.
- Actor hosts use 1024 MiB, three warm hosts and `maxStarting: 8`.
- The controller requests 1 CPU / 1 GiB and is limited to 2 GiB.
- The tested controller count remains one. Its PDB blocks voluntary eviction,
  but this is not controller or AZ HA. Multiple controllers require Redis;
  multi-zone actor placement requires a separately qualified TerseAI runtime.

No live customer change is authorized by these source and chart changes.
