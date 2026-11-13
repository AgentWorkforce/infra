# Sessions pipeline

## AWS RDS native customer profile

`profiles/aws-rds-native.yaml` composes the release shape used on EKS with
Amazon RDS, S3 through Pod Identity, OpenSearch, the read API, ingest edge, and
search indexer. It contains no customer origin, bucket, search endpoint, subnet
CIDR, CA hash, or approved services digest. Those values belong in a private
release overlay, and the chart refuses to render without them.

```bash
helm template agent-relay . -n agent-relay \
  -f profiles/aws-rds-native.yaml \
  -f /approved/private/release-values.yaml
```

The release overlay must set one reviewed services artifact under `worker`,
`alleyoop`, `sessionReadApi`, `ingestEdge`, and `searchIndexer`; the same public
History origin for read and ingest; the S3 bucket/region; OpenSearch settings;
the RDS CA SHA-256; the actual in-cluster Control Service URL used for token
introspection; and the ALB subnet peers admitted by the read API NetworkPolicy.
The chart rejects a missing or mismatched services digest before rendering.
Database credentials remain in existing Secrets created from the managed-RDS
bootstrap output. No customer credential belongs in either values file.

The search-indexer bootstrap is serialized with the Sessions migration Job by
the migrator's existing PostgreSQL advisory lock. This is deliberately not a
Helm hook: hookless installers render and apply the same resources. The Job has
`backoffLimit: 0`; its guard retries only PostgreSQL `XX000` catalog races
(`tuple concurrently updated` / `concurrent catalog update`) in the same Pod,
using `searchIndexer.bootstrap.catalogRetry`. Permission, configuration and
other database failures remain immediate failures for operator inspection.
On the RDS-native profile the guard first waits, within the Job's deadline, for
`rds-setup.sh post` to activate `search_consumer_runtime`; it does not hold the
migrator lock while waiting. Thus the documented `pre` → Helm/migrate → `post`
sequence converges without deleting and recreating a pre-post failed Job.

That artifact must be qualified as one unit. It must include the schema through
migration `046010`, the fresh-install read grants on `search_index`, and the
session-query read path selected by `READ_API_SESSION_QUERY=true`. The ingest
edge defaults `claimLockBusy: true`; the artifact must include pipeline #484
before claiming 429/Retry-After behavior for claim lock contention. An older
image can ignore that setting; no services image is selected by this change.
This does not remove the synchronous SQL claim or enable async admission.
The artifact must also come from relayhistory-pipeline `fe62ed80` or a reviewed
successor and implement `GET /v1/coordination/overlaps`; sessions-pipeline
defaults that endpoint on whenever `sessionReadApi.enabled=true`, rendering
`READ_API_COORDINATION_OVERLAPS_ENABLED=true` and
`READ_API_COORDINATION_OVERLAPS_BACKEND=postgres`. The Dashboard view is a
separate default-off selection. A digest that starts but
lacks any of those contracts is not acceptable: session list/search will answer
501, events reads will answer 503, or the Dashboard Overlaps tab will stay
hidden on 404. Record the merged source revision, successful publish run,
immutable destination digest, and a fresh-RDS read acceptance result in the
private release packet.

Migration `20261105047000_coordination_fact_readers` creates two partial
coordination-reader indexes. A fresh installation can let the migration build
them directly because the target tables are empty. Before running that migration
against a populated database, the database owner must prebuild the exact indexes
outside a transaction, one statement at a time:

```sql
CREATE INDEX CONCURRENTLY session_event_facts_coordination_writes_idx
  ON sessions.session_event_facts USING btree (org_id, workspace_id, ts, row_id)
  WHERE (cardinality(files_touched) > 0);
CREATE INDEX CONCURRENTLY session_output_facts_coordination_outcomes_idx
  ON sessions.session_output_facts USING btree (org_id, workspace_id, ts, row_id)
  WHERE (fact_kind = ANY (ARRAY['commit'::text, 'outcome'::text]));
```

Verify both indexes are valid and ready, then run the migration so it adopts
their exact definitions. Do not use the blocking-index override in production.

The profile disables the in-cluster HoopDb and MinIO, disables the legacy
alleyoop Deployment, and uses dedicated Pod Identity ServiceAccounts. The
disabled alleyoop subchart owns the native ingest edge's ServiceAccount object;
the edge selects that same name. The S3 bucket initializer is disabled because
Terraform owns bucket creation/versioning and the workload identity has object
permissions only. Run `scripts/selfhost/rds-setup.sh pre` before Helm and `post`
only after the HoopDb migration Job succeeds.

Session descriptions are deliberately a second activation. After the first
owner signs in, read the real workspace ID and add it to
`worker.nativeBrief.workspaceIds`; the value is a bounded explicit list and
never `"*"`. Repeat the render and acceptance checks when adding a workspace.

## Output facts, Output and the daily digest

`GET /v1/sessions/output`, `GET /v1/digest/daily` and coordination overlaps
all read the Postgres output facts of migration
`20261105045040_selfhost_output_facts` (commit, branch and file facts per
session). Three switches produce and serve them; the `aws-rds-native` profile
turns all three on:

| Value | Default | Renders |
| --- | --- | --- |
| `searchIndexer.outputFacts.enabled` (or `nativeConsumer.outputFacts.enabled`) | `false` | `RELAYHISTORY_SELFHOST_OUTPUT_FACTS=true` on the consumer: every indexing pass also writes the session's facts, in the same transaction as its directory events |
| `sessionReadApi.output.enabled` | `false` | `READ_API_OUTPUT_ENABLED=1`, `READ_API_OUTPUT_BACKEND=postgres` |
| `sessionReadApi.digest.enabled` | `false` | `READ_API_DIGEST_ENABLED=1`, `READ_API_DIGEST_BACKEND=postgres` |

The digest narrative model (`sessionReadApi.digest.narrative.model`) stays
unset by default, so the read API makes no model call and no session content
leaves the cluster. The digest statistics are still served; the narrative is
`provider_not_configured`. See
[the session read API guide](../../docs/self-hosted-session-read-api.md#output-and-the-daily-digest)
before setting a model.

**Database prerequisites.** None beyond the profile's normal install. The
migration grants the four facts writers to `search_consumer_runtime` and the
readers to `bulls96_read_api`, both of which `scripts/selfhost/rds-setup.sh`
already provisions; turning the writer on needs no extra role or grant. The
services image must contain migration `045040` (any artifact that serves
coordination overlaps does).

**Coverage watermark.** The read API answers a window only after the
workspace has a coverage watermark
(`sessions.output_facts_workspace_state.complete_since`). Until then every
Output and digest window answers 501 `output_backfill_incomplete` /
`digest_backfill_incomplete`, and a window that starts before it answers
`*_before_watermark`. The only writer of the watermark is the output facts
bootstrap Job, which the chart renders when
`searchIndexer.outputFacts.bootstrap.enabled=true` (default off; there is no
equivalent Job for `nativeConsumer`, run it there per the pipeline runbook
`runbooks/selfhost-output-facts-bootstrap.md`).

The Job runs `SERVICE=session-pipeline-output-facts-bootstrap` from the same
services image as the indexer, as the schema owner from
`searchIndexer.bootstrap.existingSecret` (`search-indexer-owner` in the
profile). It queues every live session that owes facts for the running
indexer, waits up to `deadlineSeconds` (default 7200) for them, then marks each
workspace whose sessions all have complete facts, with `complete_since` set to
its earliest session. A watermark is never moved once written. The Job only
marks workspaces that already have sessions, so on a fresh install:

1. Install with the writer on (the profile default) and finish
   `rds-setup.sh post`. Facts are written from the first upload onward.
2. After the first sessions of a workspace have arrived, add this to the
   private values overlay and apply it with the release's normal
   `helm upgrade ... --no-hooks` command:

   ```yaml
   sessions-pipeline:          # omit this level when installing this chart directly
     searchIndexer:
       outputFacts:
         bootstrap:
           enabled: true
           runId: "1"
   ```

   Then wait for it:
   `kubectl wait --for=condition=complete --timeout=2h job -l app.kubernetes.io/component=output-facts-bootstrap`.
3. When another workspace starts uploading, change `runId` and run it again.

The Job name is a hash of its spec and `runId`: a reapply with the same values
never reruns it, and a new `runId` renders a new Job. `backoffLimit` is 0
because its non-zero exits need an operator: 2 means refused (missing
migration, consumer bootstrap not run, or not the owner identity; nothing was
written), 3 means some workspaces still owe facts (check the indexer, then
rerun; `allowPartial: true` turns 3 into 0 and leaves those workspaces
unmarked). Running it against a database that already holds history is a
database-owner decision: it only queues work for the indexer and inserts
watermark rows, but record that approval in the release packet.

Verify as the reader role inside a tenant transaction:
`SELECT * FROM sessions.output_facts_coverage_for('<workspace>', '<from>', '<to>')`
returns a non-null `complete_since` and `incomplete = 0`.

## Native canonical consumer (default off)

`nativeConsumer` supplies a dedicated canonical pointer/Postgres-search consumer
and optional owner bootstrap Job after qualifying the merged source/image and
migration generation. See [the operator contract](../../docs/self-hosted-native-consumer.md)
for its two-pool TLS requirements, separate owner/runtime Secrets, indexer drain
and prepare/serve bootstrap order. No install profile enables it.

## Scrub-engine and reader ruleset contract

`global.scrubEngine` is one strict contract inherited by every self-host
workload and Job that runs the Services image, including ingest, read API,
publication, worker, search consumer and bootstrap entry points. Its three
fields default to empty strings and emit nothing, preserving the prior engine
and reader behavior:

```yaml
global:
  scrubEngine:
    engine: ""
    required: ""
    readerMaxRuleset: ""
```

For an existing install, phase 1 sets only `readerMaxRuleset: "10"`; verify
every Services workload is Ready or complete before phase 2 sets both `engine`
and `required` to `wasm-bindgen`. The chart then emits the exact
`SCRUB_ENGINE=wasm-bindgen`, `SCRUB_ENGINE_REQUIRED=wasm-bindgen`, and
`READER_MAX_RULESET=10` triple everywhere. A fresh install with an empty
Sessions database may start directly on the full triple because all readers
start before any object exists.

The chart refuses any engine other than empty or `wasm-bindgen`, a required
engine that differs from the selection, a non-string ceiling, and a wasm-bindgen
selection below ceiling 10. Legacy per-component `readerMaxRuleset` values are
retained as fallbacks for compatibility; when the shared ceiling is set, they
must be unset or equal it. Keep ceiling 10 during rollback while ruleset-10
objects exist. Rendering the contract does not qualify an image or prove its
runtime scrubber.

## Upload credential renewal route

When `nativeRouting.enabled=true`, `/v1/auth/token/refresh` always routes
exactly to the ingest edge, in both Control-only and independent reader modes.
The edge returns `401 refresh_not_supported`; Desktop then renews its upload
credential from its current Control sign-in. Sending this POST to the reader
returns `405` and leaves expired uploads retrying as an outage. Descendant paths
continue to use the reader; this adds no public internal issuer route.

## S3 upload ledger (decision 0005, default off)

Pipeline decision 0005 (`docs/decisions/0005-s3-native-upload-ledger.md`) moves
upload accounting (batch idempotency, stored revisions, ownership, deletion
fences, re-arm markers) from SQL into objects under each user's admission
directory. Both values below are off by default, and the default render is
byte-identical to the chart before they existed.

### `ingestEdge.ledger: sql | s3`

- `sql` (default) renders nothing and keeps the SQL ledger.
- `s3` renders `INGEST_LEDGER=s3` on the ingest edge. Every admission path of
  that process (sync, the async consumer and direct-upload promotion) then claims
  and commits through `ledger-s3.ts`. Needs a services image built from
  pipeline main `8b2430c7` or later.
- Only the ingest edge gets `INGEST_LEDGER`. It is the only workload in this
  chart that admits uploads through the upload ledger
  (`src/session-ingest/selfhost-server.ts`). The legacy `alleyoop-ingest`
  (`src/alleyoop/ingest.ts`, the pipeline chunk/manifest routes), the worker
  components and the read API never call `ledger-sql.ts` or `ledger-s3.ts`.
  The read API and the eraser still read SQL `upload_deletions`. That is why
  `s3` keeps the database requirement (see the control mirror below).
- The render fails, as the binary fails at startup
  (`selfhost-config.ts` `selfhostLedger`), when `s3` is combined with features
  whose state is SQL-only:
  - `ingestEdge.sessionSelection: true` (`RELAYHISTORY_SELFHOST_SESSION_SELECTION`);
  - the operator session erase (`global.operatorSessionErase.fenceEnforced`,
    `operatorSessionErase.api.enabled`, `operatorSessionErase.bytes.enabled`).
  - Upload consent (`INGEST_UPLOAD_CONSENT`) is never rendered by this chart and
    `ingestEdge.extraEnv` is refused, so it is always `off` here.
- With `s3`, `ingestEdge.maxPerUser` and `maxPerOrg` no longer bound the sync
  path. The S3 ledger has no tenant slots.
- The ingest's Locker credential also needs GetObject and conditional PutObject
  (`If-None-Match: *` and `If-Match`) under
  `<keyRoot>/.admission-inbox/*/ledger/` (`batches/`, `revisions/`, `owners/`,
  `rearm/`) and on `…/upload-fences.json`. A reset also needs ListBucket on
  `…/ledger/owners/`, and the markers need GetObject on
  `<keyRoot>/.ledger/fence-authority.json` and
  `<keyRoot>/.ledger/fence-authority/*`. Nothing in the S3 ledger is ever
  deleted (pipeline `docs/selfhost-composition.md`).

### Operator steps on self-host

With `s3`, **no org is admitted until a fence-authority marker covers it.**
Until then, every claim for that org is a retry, and its sync uploads answer
503. The chart never writes a marker. An operator writes one only after every
condition below holds. The fields are exactly:

```json
{"v":1,"fenceBackfill":"complete","revisionBackfill":"complete","ownershipBackfill":"complete","controlMirror":"on","rearmSweeper":"live","workerHttpAdmission":"off","writtenAtMs":<ms>}
```

- **Per org (use this first):** `<keyRoot>/.ledger/fence-authority/<org>.json`.
  Add `"orgId":"<org>"`, which must equal the org in the key.
- **Deployment-wide:** `<keyRoot>/.ledger/fence-authority.json`, with no
  `orgId`. Use it only after the full backfill of every org.

What each field asserts (`ledger-s3.ts` `FenceAuthorityDoc`), and what it means
on self-host:

1. **`workerHttpAdmission: "off"`.** The field names the hosted Worker's HTTP
   upload path, whose ledger is SQL (`INGEST_LEDGER=s3` refuses there). This
   chart has no such Worker. The condition behind the field still applies: nothing
   else may admit these users through a SQL ledger any more. For example, no other
   ingest release or replica with `ledger: sql` may serve the same bucket and key
   root. It must hold **before** the revision and ownership backfills run. An
   admission made after them would be missing from the S3 index and owner
   stubs.
2. **`fenceBackfill`, `revisionBackfill`, `ownershipBackfill: "complete"`.**
   Each user's SQL deletions and resets (`upload_deletions`, `upload_resets`)
   must be in their fence. SQL `ingest_record_revisions` must be in the revision
   index, and SQL `ingest_session_ownership` (and every session with SQL
   revisions) must be in owner stubs. These copies run after step 1. This chart
   ships no backfill Job. If the SQL tables hold nothing for the users the marker
   covers (for example, an ingest that never ran with `ledger: sql`), there is
   nothing to copy. Verify that against the database rather than assume it.
3. **`controlMirror: "on"`.** Every control route must write the S3 fence before
   SQL, so no deletion lands in SQL alone. On self-host the ledger's own controls
   do this: with `INGEST_LEDGER=s3`, selection and reset write the S3 fence first
   and then reconcile SQL `upload_deletions` (`withSqlControlMirror`). A failure
   on either side fails the control. It holds once every ingest replica serving
   these users runs `ledger: s3`. A replica on `sql` writes controls to SQL only.
4. **`rearmSweeper: "live"`.** The re-arm sweeper runs against this bucket and
   key root, armed and not in dry run (`rearmSweeper.enabled: true`,
   `dryRun: false`). With `rearmSweeper.orgs` set, it is live only for the
   listed orgs. The deployment-wide marker needs `orgs` empty.

Kill switch (pipeline `docs/selfhost-composition.md`, "Stopping admission"):

- To stop one org, write an **invalid** marker (for example `{}`) at its per-org
  key. Deleting it is not enough while a valid deployment-wide marker exists.
- To stop every org, delete or invalidate the deployment-wide marker **and**
  every per-org marker.

Either way, already-claimed batches still commit, and each warm instance stops
within its 60 s cache.

Suggested order:

1. Set `ledger: s3` and enable `rearmSweeper` in the same upgrade. The sweeper
   requires `ledger: s3`, and nothing is admitted yet. A first pass with
   `dryRun: true` is optional, but it is not live.
2. Set `dryRun: false`.
3. Confirm step 1 of the list above, then run and verify the backfills.
4. Write the per-org marker.

Enabling any of this on an environment is a deliberate operator decision.

### Re-arm sweeper (`rearmSweeper`)

A commit that a deletion, disable or reset reached after its claim writes a
re-arm marker under `…/ledger/rearm/`. The sweeper
(`rearm-sweeper.ts`) erases that session's canonical copy again and records
completion. It is a precondition of the marker's `rearmSweeper: "live"`.

- **Shape.** A CronJob (`<release>-rearm-sweeper`). The default schedule is
  `*/5 * * * *` with `concurrencyPolicy: Forbid`, `backoffLimit: 0` and
  `activeDeadlineSeconds: 1800`. It runs one pass of
  `bun run /app/src/session-ingest/rearm-sweeper-main.ts`. The image's
  `SERVICE=s3-ledger-rearm-sweeper` entry runs `--loop` for a Deployment, so the
  CronJob runs the one-shot main directly.
- **Exit codes and resume.** A pass exits:
  - `0` when complete;
  - `3` when incomplete or a marker failed;
  - `2` when refused or misconfigured, for example `access_denied` on a
    401/403;
  - `4` on any other failure.

  A real pass saves its position in a durable cursor at
  `<keyRoot>/.ledger/rearm-sweeper/cursor-<hash>.json`, so a failed or killed
  Job resumes on the next tick. Alert on failed Jobs, and on the `corrupt` count
  in the one JSON line each pass logs.
- **Targets.** Image, bucket, region, endpoint, `ALLOW_IN_CLUSTER_HTTP` and key
  root are taken from `ingestEdge`. They are never set separately, because
  "live" means this bucket and key root. Optional:
  - `orgs` (`INGEST_REARM_ORGS`);
  - `dryRun` (`INGEST_REARM_DRY_RUN=1`, no write and no delete, so not live);
  - `concurrency` (1-16) and `maxMarkers` (1-10000).
- **Credentials.** `credentials.mode` is `secret` (the default) or
  `podIdentity`:
  - `secret`: set a dedicated `existingSecret`. The chart mounts it as files and
    sets `INGEST_REARM_CREDENTIALS=keys` with `INGEST_REARM_S3_*_FILE`. The render
    refuses the ingest runtime, Locker writer and upload witness Secrets, because
    this credential deletes object versions.
  - `podIdentity`: the chart sets `INGEST_REARM_CREDENTIALS=podIdentity` and
    nothing else, and mounts no Secret (`existingSecret` must stay empty). The EKS
    Pod Identity agent injects `AWS_CONTAINER_CREDENTIALS_FULL_URI` and
    `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, and the endpoint must be the trusted
    Pod Identity address. The binary reads them through the same helper as every
    Locker client (`src/shared/locker.ts`).
    - It needs `serviceAccountName` with its own Pod Identity association. The
      render refuses the ingest's ServiceAccount, because the sweeper's role
      deletes object versions.
    - It needs a services image built from pipeline main `9be2ad8e`
      (relayhistory-pipeline #602) or later. An older image refuses the mode at
      startup and exits `2`.
    - A pass ends 5 minutes before the Pod's credentials expire, and refuses to
      start (`credentials_expiring`, exit `2`) if they are already that close.
    - An error from the container credential endpoint exits `4` (retryable, the
      next tick tries again). A missing or untrusted endpoint exits `2`.
  - `webIdentity` (IRSA) is refused: the binary has no web identity mode.
  - `serviceAccountName` (and `createServiceAccount`) give the Pod its own
    identity in either mode.
- **Requirements.** `ingestEdge.enabled: true`, `ingestEdge.ledger: s3` and
  `ingestEdge.locker.provider: s3`. The sweeper lists and deletes S3 object
  versions.

#### Re-arm sweeper IAM

Derived from the operations in `rearm-sweeper.ts`, `rearm-sweeper-main.ts` and
the shared eraser (`neon-s3-erasure/eraser.ts`), matching the pipeline's
`docs/selfhost-composition.md`:

- `s3:ListBucket` on the bucket, **unconditioned**. A prefix condition turns the
  HEAD of a missing completion record into a 403, which aborts the pass with
  `access_denied`.
- `s3:GetObject` (GET and HEAD) on:
  - `<keyRoot>/.admission-inbox/*/ledger/rearm/*` (markers and their
    `.done/`/`.corrupt/` records);
  - `<keyRoot>/.admission-inbox/*/ledger/owners/*`;
  - `<keyRoot>/.admission-inbox/*/upload-fences.json`;
  - `<keyRoot>/.ledger/rearm-sweeper/*`;
  - the canonical `…/manifest.json` (deriving an unstamped owner stub's machine).
- `s3:PutObject` (conditional) on:
  - `<keyRoot>/.admission-inbox/*/ledger/rearm/*.done/*`;
  - `<keyRoot>/.admission-inbox/*/ledger/rearm/*.corrupt/*`;
  - `<keyRoot>/.ledger/rearm-sweeper/*` (the cursor).
- `s3:ListBucketVersions` on the bucket, and `s3:DeleteObjectVersion` on the
  canonical layout. This covers each session's transcript directory
  `<keyRoot>/<org>/v1/ws=…/m=srv_…/h=…/` and its live pointer
  `<keyRoot>/<org>/live-sessions/v1/ws=…/m=srv_…/h=…/`.
- With SSE-KMS on the bucket, the matching `kms:Decrypt` and
  `kms:GenerateDataKey` grants on the key.
- The same policy applies to the static-key user (`secret`) or to the Pod
  Identity role (`podIdentity`).

The sweeper never deletes a ledger object, never writes SQL and never writes
search. For index and search rows, `rearm-sweeper.ts` relies on the
`ObjectRemoved:Delete` events of its version deletes reaching the indexer.
Whether a self-host consumer receives those events depends on that install's
bucket notifications. This chart does not configure them.
