# GCP backup, restore, and rollback

This runbook covers the `agent-relay` `portable-single` suite:

- PostgreSQL databases for the Sessions Pipeline (`hoopdb`, which also holds
  native History: read API, ingest edge and search projection) and the control
  API;
- Relaycast SQLite and uploaded files on its retained RWO PVC;
- RelayAuth SQLite on its retained RWO PVC;
- Sessions Pipeline Locker objects in GCS.

A recovery set is valid only when all artifacts use one recovery ID, carry a
`COMPLETE` marker naming that ID, and are captured while application writes
are stopped: every writer matching `WRITER_SELECTOR` scaled to zero, recorded
as `writesQuiesced: true` (see [Capture](#capture); set
`REQUIRE_WRITES_QUIESCED=true` to fail rather than record a crash-consistent
set). Cloud SQL backups are
instance-wide; repeat the database steps when the databases use separate
instances.

## Safety rules

- Never restore directly over production during a drill.
- Restore into a separate Cloud SQL instance, GCS bucket, namespace, PVCs, and
  Helm release.
- Initially use the exact recorded chart version and immutable image digests.
- Keep credentials in the approved secret manager and out of evidence files.
- Do not run migrations or `helm upgrade` during capture or restore.
- Preserve the failed production state before rollback.
- Verify a recovery ID ownership label before deleting any temporary resource.
- Do not use Helm `--atomic` as a recovery control. Helm can change Kubernetes
  resources after a failed release, but it cannot reverse database migrations
  or restore PostgreSQL, SQLite, PVC, or GCS data.
- Do not automatically run `helm rollback`, uninstall, or retry a migration
  after failure. First identify which migrations and writes completed.

## Pre-upgrade recovery gate

Every upgrade that can run a database or data migration requires all of the
following before `helm upgrade`:

1. a migration compatibility review from the current chart and image versions
   to the exact target versions, classifying each migration as
   backward-compatible or forward-only;
2. a complete recovery set captured by `gcp-recovery-backup.sh` from the
   currently deployed Helm revision while writes are quiesced: its
   `evidence/backup.json` must record `writesQuiesced: true`, which requires
   every writer matching `WRITER_SELECTOR` at zero replicas for the whole
   capture (run with `REQUIRE_WRITES_QUIESCED=true` to fail fast). The capture
   needs `helm` and RBAC to read Helm release storage (Secrets) in the release
   namespace;
3. a successful isolated restore of that recovery set, including all
   verification gates below;
4. an approved database-aware recovery strategy: database restore or
   side-by-side restore and traffic cutover;
5. confirmation that no migration or backup Job is active or failed.

Record these as non-secret JSON evidence and run the read-only gate documented
in [`scripts/selfhost/README.md`](../scripts/selfhost/README.md):

```bash
scripts/selfhost/pre-upgrade-check.sh \
  --context "$(kubectl config current-context)" \
  --namespace "$KUBERNETES_NAMESPACE" \
  --release "$HELM_RELEASE" \
  --target-chart ./charts/agent-relay \
  --backup-evidence "$EVIDENCE_DIR/backup.json" \
  --restore-evidence "$EVIDENCE_DIR/restore.json" \
  --compatibility-evidence "$EVIDENCE_DIR/compatibility.json"
```

A successful gate does not make a migration reversible and does not authorize
the upgrade. Keep the normal review and explicit mutation approval.

## Capture

Capture a recovery set with `charts/agent-relay/scripts/gcp-recovery-backup.sh`.
Do not hand-assemble one: the pre-upgrade gate and the restore drill scripts
read the layout and evidence this script writes. A manual capture is valid only
if it reproduces the same contract exactly:

- recovery ID `ar-<UTC timestamp>Z-<suffix>`, for example
  `ar-20261102T140500Z-manual`; the suffix is the lowercase alphanumeric first
  eight characters of `POD_UID` (default `manual`);
- everything under `gs://<archive bucket>/recovery/<recovery ID>/`
  (`ARCHIVE_PREFIX`, default `recovery`):
  - `cloudsql/<database>.sql.gz`: one Cloud SQL export per database, alongside
    an on-demand Cloud SQL backup whose description is the recovery ID;
  - `gcs/`: a copy of the Sessions source bucket;
  - `evidence/backup.json`: the non-secret evidence the pre-upgrade gate reads;
  - `COMPLETE`: written last, containing exactly the recovery ID;
- one retained `VolumeSnapshot` each for Relaycast and RelayAuth, named
  `vs-<lowercase recovery ID>-<component>` and labelled `recovery-id`.

A recovery set without a `COMPLETE` marker naming its own ID is incomplete and
must not be restored. A failed run leaves `evidence/FAILED.json` instead.

### Requirements

The script needs `gcloud`, `kubectl`, `helm`, and `python3`. Authentication is
GKE Workload Identity or the operator's own `gcloud` login; it has no
credential-file path. The identity needs:

- Cloud SQL backup and export rights on the instance;
- read and list access to the source bucket (`GCS_SOURCE_BUCKET`), which the
  `gcs-copy` phase copies from, plus read (bucket metadata), list, and write
  access to the archive bucket (`GCS_ARCHIVE_BUCKET`);
- the Cloud SQL instance's service agent (shown as `serviceAccountEmailAddress`
  in `gcloud sql instances describe`) needs `roles/storage.objectCreator` on
  the archive bucket. Cloud SQL writes the export files as that agent, not as
  the script's identity, so the export fails without it:
  `gcloud storage buckets add-iam-policy-binding gs://$GCS_ARCHIVE_BUCKET --member="serviceAccount:<service-agent>" --role=roles/storage.objectCreator`;
- Kubernetes rights in the release namespace to list Deployments,
  StatefulSets, and Pods (the quiesce check), read PVCs, and create and read
  `VolumeSnapshot` objects;
- cluster-scoped read (`get`) on the `VolumeSnapshotClass` named by
  `SNAPSHOT_CLASS`, which the `snapshot-policy-preflight` phase checks before
  either snapshot is created, and on `VolumeSnapshotContent`;
- **Helm release-storage access:** the script runs `helm status` before and
  after the capture to record the deployed revision (`sourceRevision`) and
  fails if it changes. Helm stores releases as Secrets and reads the latest
  release by listing them by label, so the identity needs `list` on Secrets in
  the release namespace.

The archive bucket must differ from the source bucket and enforce a locked
retention policy of at least `RETENTION_DAYS` (minimum 35), uniform
bucket-level access, and public access prevention. The snapshot class must use
`deletionPolicy: Retain`.

Set the environment:

```bash
export PROJECT_ID="customer-project"
export REGION="us-central1"
export CLUSTER="customer-gke"
export KUBERNETES_NAMESPACE="agent-relay"
export HELM_RELEASE="agent-relay"
export CLOUDSQL_INSTANCE="agent-relay-postgres"
export CLOUDSQL_DATABASES="hoopdb,control_api"   # your database names
export GCS_SOURCE_BUCKET="customer-session-locker"
export GCS_ARCHIVE_BUCKET="${PROJECT_ID}-agent-relay-backups"
export SNAPSHOT_CLASS="approved-retain-snapshot-class"
export RELAYCAST_PVC="<from kubectl get pvc>"
export RELAYAUTH_PVC="<from kubectl get pvc>"
export RETENTION_DAYS=35 RPO_MINUTES=15 RTO_HOURS=4
# Writers that must be scaled to zero; defaults to the release's instance label.
export WRITER_SELECTOR="app.kubernetes.io/instance=${HELM_RELEASE}"
# Fail instead of recording a crash-consistent capture.
export REQUIRE_WRITES_QUIESCED=true
export EVIDENCE_DIR="./evidence/$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$EVIDENCE_DIR"
gcloud config set project "$PROJECT_ID"
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION"
```

Discover the PVC names; do not infer them from the release name:

```bash
kubectl -n "$KUBERNETES_NAMESPACE" get pvc \
  -o custom-columns=NAME:.metadata.name,APP:.metadata.labels.app\\.kubernetes\\.io/name
```

Record Helm state and inventory without exporting credential values. Raw
`helm get values -a` and `helm get manifest` output is not safe evidence: an
inline `relayflows.credentials.enrollmentToken` appears in the computed values,
and the chart-managed Secret it renders appears in the manifest. Redact both
before writing anything to the evidence directory, and prefer
`relayflows.credentials.existingSecret` in any install that produces evidence:

```bash
helm history "$HELM_RELEASE" -n "$KUBERNETES_NAMESPACE" -o json \
  > "$EVIDENCE_DIR/helm-history.json"
helm get values "$HELM_RELEASE" -n "$KUBERNETES_NAMESPACE" -a -o yaml |
  yq 'del(.relayflows.credentials.enrollmentToken)' \
  > "$EVIDENCE_DIR/helm-values.yaml"
helm get manifest "$HELM_RELEASE" -n "$KUBERNETES_NAMESPACE" |
  yq 'select(.kind != "Secret")' \
  > "$EVIDENCE_DIR/helm-manifest.yaml"
helm get manifest "$HELM_RELEASE" -n "$KUBERNETES_NAMESPACE" | sha256sum \
  > "$EVIDENCE_DIR/helm-manifest.sha256"
kubectl -n "$KUBERNETES_NAMESPACE" get deploy,statefulset,job,cronjob,pvc -o wide \
  > "$EVIDENCE_DIR/kubernetes-inventory.txt"
gcloud sql instances describe "$CLOUDSQL_INSTANCE" --format=json \
  > "$EVIDENCE_DIR/cloudsql-source.json"
gcloud storage buckets describe "gs://${GCS_SOURCE_BUCKET}" --format=json \
  > "$EVIDENCE_DIR/gcs-source.json"
```

Before keeping the evidence, confirm the redaction held:
`grep -n enrollmentToken "$EVIDENCE_DIR/helm-values.yaml"` must print nothing,
and the redacted manifest must contain no `kind: Secret` document. If either
check fails, delete the file and stop. Because the redacted values omit inline
credentials, a restore from `recorded-values.yaml` must supply them through an
`existingSecret` in the target namespace.

Confirm that no migration or backup Job is running and that the three database
URLs select dedicated databases. Capture non-secret canaries: workspace,
agent, message, and session IDs; per-database table counts; and GCS object
count and bytes.

### 1. Quiesce writes

`WRITER_SELECTOR` (default `app.kubernetes.io/instance=<release>`) selects the
Deployments, StatefulSets, and Pods the script treats as writers. It records
`writesQuiesced: true` only when at least one controller matches, every match
has zero desired and zero running replicas, and no matching Pod is left that is
not `Succeeded` or `Failed` (a terminating Pod still counts), both before and
after the capture. Before the capture it waits up to `QUIESCE_WAIT_SECONDS`
(default 300) for scaled-down Pods to finish terminating. Otherwise the
capture is recorded as crash-consistent with `writesQuiesced: false`, which the
pre-upgrade gate rejects. With `REQUIRE_WRITES_QUIESCED=true` the script fails
instead.

Enable maintenance mode at the public edge. Record replica counts, then scale
every writer to zero:

```bash
kubectl -n "$KUBERNETES_NAMESPACE" get deploy,statefulset \
  -l "$WRITER_SELECTOR" -o json \
  > "$EVIDENCE_DIR/writers-before.json"
kubectl -n "$KUBERNETES_NAMESPACE" scale deploy,statefulset \
  -l "$WRITER_SELECTOR" --replicas=0
```

### 2. Run the capture

```bash
bash charts/agent-relay/scripts/gcp-recovery-backup.sh
```

The script snapshots both PVCs, creates the Cloud SQL backup and per-database
exports, copies the source bucket to `gcs/`, writes `evidence/backup.json`,
and finally writes `COMPLETE`. It prints the recovery ID and evidence URI.
Record the ID, then copy the evidence locally for the pre-upgrade gate:

```bash
export RECOVERY_ID="<printed recovery ID>"
export RECOVERY_URI="gs://${GCS_ARCHIVE_BUCKET}/recovery/${RECOVERY_ID}"
test "$(gcloud storage cat "${RECOVERY_URI}/COMPLETE")" = "$RECOVERY_ID"
gcloud storage cp "${RECOVERY_URI}/evidence/backup.json" \
  "$EVIDENCE_DIR/backup.json"
jq -e '.writesQuiesced == true and .artifactsComplete == true' \
  "$EVIDENCE_DIR/backup.json"
```

If Relaycast chart backups are enabled, retain a completed online backup as a
second recovery path. Only backup directories containing `COMPLETE` are valid.

### 3. Resume production

Restore recorded replica counts. Remove maintenance mode only after readiness,
ingress, messaging, ingest, search, and replay checks pass.

## Isolated restore drill

Create uniquely named target resources labeled with the recovery ID:

- separate namespace and Helm release;
- separate Cloud SQL instance restored from the selected backup;
- separate GCS bucket populated from `gs://<archive>/recovery/<recovery ID>/gcs/`;
- separate Relaycast and RelayAuth PVCs created from imported snapshots;
- separate Kubernetes Secret objects populated through approved secret
  delivery.

The target must have no production ingress or DNS and no route to production
databases or buckets.

For cross-namespace CSI restore, create uniquely named pre-provisioned
`VolumeSnapshotContent` objects using the retained snapshot handles, import
them into target-namespace `VolumeSnapshot` objects, then create RWO PVCs.
Requested sizes must be at least the source sizes. Never bind source PVs or
PVCs into the target.

Keep the restore on the recorded chart version. For pre-rename charts, use
`relay-cloud-api.migrations.enabled=false` and keep the original recorded values
keys. The `relay-control` example below applies only to a recorded version with
the renamed chart. If an upgrade is explicitly part of a separately reviewed
drill, first translate recorded values using the
[rename guide](control-webapp-chart-rename.md), retain observed identities, and
verify the selected chart reads every migration-disable key before applying.
Do not combine old recorded values with renamed keys that the chart ignores.

Install with an isolated overlay. The migration and Locker initialization Jobs
are plain Kubernetes Jobs, not Helm hooks, so `--no-hooks` does not stop them;
the overlay must disable them explicitly. The restored databases already carry
the recorded schema, and the restored bucket already exists:

- `relay-control.migrations.enabled=false`;
- `sessions-pipeline.worker.migrations.enabled=false`;
- `sessions-pipeline.worker.lockerInit.enabled=false`;
- `relaycast.backup.enabled=false`, so no backup CronJob writes during the
  drill;
- `gkeIngress.enabled=false` and all leaf ingresses disabled;
- `relaycast.persistence.existingClaim` set to the restored Relaycast PVC;
- `relayauth.persistence.existingClaim` set to the restored RelayAuth PVC;
- all database URLs pointing only to the restored instance;
- Locker bucket pointing only to the restored bucket;
- the recorded chart version and immutable image digests;
- for a recorded chart before agent-relay 0.7.0 that still ran the standalone
  RelayHistory, also `relayhistory.migrations.enabled=false`.

For example, `isolated-restore-overlay.yaml` starts with:

```yaml
gkeIngress:
  enabled: false
relay-control:
  migrations:
    enabled: false
sessions-pipeline:
  worker:
    migrations:
      enabled: false
    lockerInit:
      enabled: false
relaycast:
  backup:
    enabled: false
```

Render first and confirm the target manifest contains no `Job` objects before
installing:

```bash
helm template "$TARGET_RELEASE" ./charts/agent-relay \
  --namespace "$TARGET_NS" --no-hooks \
  -f recorded-values.yaml \
  -f isolated-restore-overlay.yaml |
  yq 'select(.kind == "Job" or .kind == "CronJob") | .metadata.name'
# must print nothing

helm install "$TARGET_RELEASE" ./charts/agent-relay \
  --namespace "$TARGET_NS" --create-namespace --no-hooks \
  -f recorded-values.yaml \
  -f isolated-restore-overlay.yaml \
  --wait --timeout 30m
```

## Verification gates

A restore passes only when:

- every target resource has the recovery ID and no target manifest or
  Workload Identity binding references production;
- all pods use the recorded immutable images;
- each PostgreSQL connection selects the expected dedicated database, roles
  retain runtime/migration separation, migrations match, and table counts are
  plausible;
- `PRAGMA integrity_check;` returns `ok` for both `relaycast.db` and
  `relayauth.db`;
- Relaycast contains the known workspace, agents, message, and files;
- GCS counts and bytes match, with matching CRC32C for approved samples;
- an isolated two-agent ping and reply succeeds;
- the known session can be found and replayed;
- identical delivery retry remains idempotent; and
- cross-workspace access is denied.

Record commands, timestamps, results, and operator approval without tokens,
password-bearing URLs, private keys, or Secret values.

## Recovery and cleanup

Prefer side-by-side recovery: block writes, preserve a forensic backup of the
failed state, restore one complete recovery set into new resources, pass every
gate, and switch traffic only after approval. Never mix recovery IDs.

Helm rollback restores release-managed Kubernetes manifests; it does not undo
PostgreSQL or SQLite schema changes, reverse transformed or deleted rows, or
restore PVC and GCS contents. Use `helm rollback` only when reviewed
compatibility evidence proves the previous application can safely run against
the post-migration data. Even then, the database remains migrated.

For a forward-only or uncertain migration, restore the pre-upgrade Cloud SQL
backup, both matching PVC snapshots, and the matching `recovery/<recovery ID>/gcs/` copy into
isolated resources. Install the recorded chart and immutable image versions,
verify them, and cut over only after approval. Never restore only one data
store from a recovery set.

Cleanup applies only to isolated targets. Before deletion, assert each
resource's `recovery-id` label equals the selected recovery ID. If any check
fails, stop. Never delete production databases, buckets, PVCs, retained
snapshots, recovery prefixes, or secret-manager versions as part of drill
cleanup.
