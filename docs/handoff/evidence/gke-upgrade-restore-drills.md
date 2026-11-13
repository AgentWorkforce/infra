# GKE upgrade and backup/restore drills (2026-11-03)

(The standalone RelayHistory component referenced here was removed in
agent-relay 0.7.0; History is now the native read API and ingest edge.)

Run in an isolated namespace and a dedicated Cloud SQL instance on the GKE
reference cluster, using the customer profile (`charts/agent-relay/values-gcp.yaml`,
all six components) plus a drill overlay for the drill's own database, bucket,
Pub/Sub and secrets. Internal identifiers are removed.

## Backup and isolated restore (agent-relay 0.1.1)
- `charts/agent-relay/scripts/gcp-recovery-backup.sh` with
  `REQUIRE_WRITES_QUIESCED=true`: writers were scaled to zero for 314 s.
  The script recorded `writesQuiesced: true` and `artifactsComplete: true`.
- The archive bucket (locked 35-day retention policy) holds the Cloud SQL
  export per database (3), a copy of the sessions bucket, and the evidence,
  including the snapshot handles. The Cloud SQL backup is held by Cloud SQL.
  The Relaycast and RelayAuth PVC snapshots are Kubernetes `VolumeSnapshot`s
  with a `Retain` deletion policy; they are cluster/storage resources outside
  the bucket, so the bucket's retention lock does not protect them.
  After the drill, cleanup deleted the snapshots and the drill's Cloud SQL
  instance with its backups; the exports, the bucket copy and the evidence
  remain in the locked archive. This is a deviation from the runbook
  (`docs/selfhost-backup-restore.md`), made only because the drill's source
  install and data were disposable. A customer must keep the recovery set's
  snapshots and backup, and delete only the isolated restore target.
- The restore went into a new Cloud SQL instance, bucket, namespace and Helm
  release, with PVCs from imported snapshots and no Jobs rendered. The restore
  record (`restore.json`) has seven verification gates, and all passed:
  - `cloudSql`: the database migration ledgers match the source (control
    plane 8, Sessions 17, RelayHistory 47 rows), and runtime and migration
    roles are still separate;
  - `relaycastIntegrity` and `relayauthIntegrity`: `PRAGMA integrity_check`
    returns `ok`;
  - `gcsIntegrity`: GCS object names, sizes and CRC32C match;
  - `isolatedMessaging`: the known agents and DM are present, and a new
    two-agent ping and reply works;
  - `crossWorkspaceDenied`: cross-workspace access is denied;
  - `noProductionReferences`: no database host, Workload Identity member or
    hostname in the restore manifest refers to production.
  The same run also checked the remaining runbook checks
  (`docs/selfhost-backup-restore.md`, "Verification gates"): all pods ran the
  recorded images; the known session lists, replays and is found by search;
  and an identical delivery retry is idempotent.
- No data loss between the quiesce point and the capture: writers stayed at
  zero from the quiesce (the recovery point) until the capture finished. This
  is a quiesced, consistent restore; it does not measure RPO under live
  writes. RTO was 387 s to all pods Ready and 578 s to all gates passed. The
  target Cloud SQL instance was created in parallel with the capture; a cold
  restore adds about 189 s for instance creation, so about 767 s (about
  12.8 minutes). The targets are 15 minutes RPO and 4 hours RTO.
- Caveat: the first delivery-gate attempt failed because of a bug in the test
  harness, not the product. A rerun with a fresh marker passed, and all
  attempts are recorded.

## Pre-upgrade gate and upgrade (0.1.1 to the release candidate)
- `scripts/selfhost/pre-upgrade-check.sh` against the release-candidate chart (then versioned 0.3.0, before the upstream `96bulls` to `sessions-pipeline` chart rename that the published 0.3.1 also contains): OK
  (backup PASS, isolated restore PASS, migrations backward-compatible,
  side-by-side-restore rollback strategy, no active or failed Jobs).
- `helm upgrade` finished with all pods Ready in 23 s. No migration re-ran,
  and 17 of 17 post-upgrade checks passed: messaging, the control-plane org
  and workspaces, sessions list, replay and search, the sessions pipeline,
  cross-workspace denial, dashboard `/healthz` and `/runtime-config.js`, and
  service health.
- RelayHistory migrations (live-proof image, relayhistory-cloud `74a6e526`,
  not a release image): 47 files in the image, 47 ledger rows, and all 47
  checksums match.
- Partial against the release manifest: the dashboard ran the release image,
  and Relaycast and RelayAuth ran their release pins. The control-plane API
  (`selfhost-api`) ran its previous image, because the release package isn't
  public yet; its migrations are byte-identical to the release revision's.
  RelayHistory and Sessions ran the live-proof images, because their release
  images aren't published yet.
- Not covered: the drill overlay kept the interim RelayAuth bearer opt-in on
  for session ingest.
