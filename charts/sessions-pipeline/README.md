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
The artifact must also
implement `GET /v1/coordination/overlaps`; this profile enables that endpoint
through `sessionReadApi.coordinationOverlaps.enabled`. A digest that starts but
lacks any of those contracts is not acceptable: session list/search will answer
501, events reads will answer 503, or the Dashboard Overlaps tab will stay
hidden on 404. Record the merged source revision, successful publish run,
immutable destination digest, and a fresh-RDS read acceptance result in the
private release packet.

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

## Native canonical consumer (default off)

`nativeConsumer` supplies a dedicated canonical pointer/Postgres-search consumer
and optional owner bootstrap Job after qualifying the merged source/image and
migration generation. See [the operator contract](../../docs/self-hosted-native-consumer.md)
for its two-pool TLS requirements, separate owner/runtime Secrets, indexer drain
and prepare/serve bootstrap order. No install profile enables it.

## Reader ruleset ceiling

The compatibility surfaces expose independent `readerMaxRuleset` values and render
`READER_MAX_RULESET`: `nativeConsumer`, `worker.nativeBrief`, `sessionReadApi`,
`alleyoop`, and `ingestEdge`. Every value defaults to `8` and accepts only `8`, `9`, or `10`.
The ingest-edge engine initializer also uses this ceiling to reject an incompatible
Rust/WASM pin before loading it. A ceiling does not select the writer ruleset,
enable a component, or activate Rust/WASM behavior.

Raise readers before any writer can emit a newer ruleset, using an immutable
services image containing relayhistory-pipeline #489 at `0ad0813c` or a
reviewed successor. The five values deliberately do not have to match during a
staged rollout. Before writer activation, prove each required read path against
representative objects. If newer objects have been written, keep the readers at
the needed ceiling during rollback; rolling this chart back to the default `8`
does not convert those objects.

## Upload credential renewal route

When `nativeRouting.enabled=true`, `/v1/auth/token/refresh` always routes
exactly to the ingest edge, in both Control-only and independent reader modes.
The edge returns `401 refresh_not_supported`; Desktop then renews its upload
credential from its current Control sign-in. Sending this POST to the reader
returns `405` and leaves expired uploads retrying as an outage. Descendant paths
continue to use the reader; this adds no public internal issuer route.
