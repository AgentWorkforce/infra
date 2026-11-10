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
the RDS CA SHA-256; and the ALB subnet peers admitted by the read API
NetworkPolicy. Database credentials remain in existing Secrets created from
the managed-RDS bootstrap output. No customer credential belongs in either
values file.

That artifact must be qualified as one unit. It must include the schema through
migration `046010`, the fresh-install read grants on `search_index`, and the
session-query read path selected by `READ_API_SESSION_QUERY=true`. It must also
implement `GET /v1/coordination/overlaps`; this profile enables that endpoint
through `sessionReadApi.coordinationOverlaps.enabled`. A digest that starts but
lacks any of those contracts is not acceptable: session list/search will answer
501, events reads will answer 503, or the Dashboard Overlaps tab will stay
hidden on 404. Record the merged source revision, successful publish run,
immutable destination digest, and a fresh-RDS read acceptance result in the
private release packet.

The profile disables the in-cluster HoopDb and MinIO, disables the legacy
alleyoop Deployment, and uses dedicated Pod Identity ServiceAccounts. Run
`scripts/selfhost/rds-setup.sh pre` before Helm and `post` only after the
HoopDb migration Job succeeds.

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
