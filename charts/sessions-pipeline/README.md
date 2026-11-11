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

## Reader ruleset ceiling

The compatibility surfaces expose independent `readerMaxRuleset` values and render
`READER_MAX_RULESET`: `nativeConsumer`, `worker.nativeBrief`, `sessionReadApi`,
`alleyoop`, and `ingestEdge`. Every value defaults to `null`, omitting the
environment binding and preserving legacy reads. Explicit `8`, `9`, or `10` opts into strict marker and chunk checks.
The ingest-edge engine initializer also uses this ceiling to reject an incompatible
Rust/WASM pin before loading it. The pin gate retains its own ceiling of 8 when
unset. A ceiling does not select the writer ruleset,
enable a component, or activate Rust/WASM behavior.

Raise readers before any writer can emit a newer ruleset, using an immutable
services image containing the reviewed #489 compatibility and binding fixes. The five values deliberately do not have to match during a
staged rollout. Before writer activation, prove each required read path against
representative objects. If newer objects have been written, keep the readers at
the needed explicit ceiling during rollback. Removing the policy or rolling back
the chart does not convert those objects.

## Upload credential renewal route

When `nativeRouting.enabled=true`, `/v1/auth/token/refresh` always routes
exactly to the ingest edge, in both Control-only and independent reader modes.
The edge returns `401 refresh_not_supported`; Desktop then renews its upload
credential from its current Control sign-in. Sending this POST to the reader
returns `405` and leaves expired uploads retrying as an outage. Descendant paths
continue to use the reader; this adds no public internal issuer route.
