# Native session ingest chart slot

`sessions-pipeline.ingestEdge` adds the `SERVICE=session-ingest` runtime from
pipeline [#363](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/363),
merged as `974e6f74343d60dbd65a44c43aab9479dd072efe`. It is disabled by default,
has no default image digest, and no installation profile enables it. Its separate
Deployment and ClusterIP Service do not replace the internal `alleyoop-ingest`
worker or change the existing providers, routes, image pins or persistent claims.

The supported first assembly is **test/pilot data only**. Product selection,
reset, erasure and privacy controls are incomplete. This chart change is not
permission to ingest real data or delete existing data, and is not full-app
acceptance. Publication and GC remain dormant. No buffered admission, custody or
frontier rows are manufactured by the chart.

## Inputs

Supply an explicit registry DNS host and image path, plus a qualified digest
whose exact image contains the merged service. The
previous reader-only image does not contain this entrypoint. Chart rendering
does not verify an image's source, generation, role grants or behavior.
The container port is restricted to 1024–65535 for the non-root, capability-free
process; its default is 8081. This is independent of the public origin port.
The shared Deployment/Service name must be a letter-first DNS-1035 label.

The following is a configuration shape, not deployable values:

```yaml
ingestEdge:
  enabled: true
  image:
    repository: ghcr.io/agentworkforce/96bulls-services
    digest: "<qualified combined-image digest>"
  origin: https://history.kind.agentrelay.com:8443
  allowInClusterHttp: true
  relaycontrol:
    url: http://relay-control.agent-relay.svc.cluster.local
  config:
    existingSecret: native-ingest-runtime
  postgres:
    caConfigMap: postgres-ca
    caSha256: "<SHA256 of the exact mounted PEM bytes>"
  locker:
    bucket: "<existing pilot bucket>"
    endpoint: http://locker.agent-relay.svc.cluster.local:9000
    existingSecret: native-ingest-store
```

Use the observed Service identities. The example's `relay-control` is the new
layout name; the compatibility overlay retains `relaycontrol`, so its Control
base URL is `http://relaycontrol.agent-relay.svc.cluster.local`. Keep the separate
`kind-locker` release and its existing `locker` Service/PVC; this slot renames
none of them.

The runtime Secret needs `database-url` and `introspect-secret`. The database URL
must authenticate as the genuine least-privilege `bulls96_session_ingest` login,
not a migration owner or a connection that switches roles. The object-store
Secret needs `access-key-id` and `secret-access-key`. Key names can be changed
through the structured values. The chart never creates or prints credentials.

PostgreSQL must already serve TLS with the correct Service DNS certificate.
The CA ConfigMap supplies `ca.crt` (key configurable), mounted read-only at
`/etc/session-ingest-postgres/ca.crt`; the chart selects `custom-ca` and pins its
hash. It does not configure PostgreSQL TLS, generate trust, or run migrations.
HTTP destination origins require qualified Kubernetes Service DNS and the
explicit in-cluster opt-in; public plaintext destinations are refused.

`relaycontrol.url` is a **base origin**, without the introspection path: the
client appends `/internal/v1/auth/introspect`. `origin` is a normalized public
HTTPS origin (lowercase DNS, no `:443` default port or trailing slash) and must
equal the reader's `READ_API_ORIGIN`; rendering refuses unequal `sessionReadApi.origin`
and `ingestEdge.origin` when both slots are enabled. A generic `extraEnv` override is refused;
the source's enablement, auth, TLS, inline acceptance and Secret inputs are
managed by the chart.

The native wrapper itself fixes inline canonical acceptance and disables the
replica. The chart emits no `INGEST_ACCEPTANCE_MODE`, `INGEST_REPLICA_MODE`,
custody/privacy authority, signing-key, publication or GC variables.

## Composition and startup

The pipeline owner requires bare-role bootstrap, migration and role verification
before services; search schema/read-role setup and the reviewed consumer bootstrap
are separate prerequisites. Drain old servers before changing the schema floor;
`Recreate` does not order migration Jobs or make rollback data-compatible.

For the inline pilot, the ingest root is fixed to `96bulls`. On the consumer and
reader, set `PIPELINE_KEY_PREFIX=96bulls` (not `96bulls/<org>`) and
`PIPELINE_ORG_FROM_PREFIX=true`, with the same qualified coverage floor. Existing
lazy-policy, org admission or buffered-batch markers make the canonical path
refuse. Never remove them to force eligibility. An existing data-bearing fixture
is not automatically an eligible fresh pilot database.

Only these public routes belong to the ingest edge after a reviewed single-origin
router is supplied:

- `POST /v1/delivery/batches`
- `POST /v1/turns/batches`
- `GET /v1/delivery/limits`

Use exact paths and test the backend's wrong-method refusal. Keep delivery records
on the reader. Selection/reset/recovery/onboarding are not working features;
probe and custody endpoints stay private. The edge re-introspects the bearer and
requires `rth:sync` on every request, ignoring client identity/signature headers.
The reader's sync-login flag must be enabled only when both services actually
serve the same origin. This PR adds no ingress. For a compatible image containing
merged pipeline #364 (`8a075b26`), select `sessionReadApi.auth.mode=relaycontrol_only`,
enable `sessionReadApi.auth.relaycontrol.enabled`, supply its URL and Secret reference,
and clear both `sessionReadApi.auth.relayauth` fields. The chart emits
`READ_API_AUTH_MODE=relaycontrol_only` and omits `RELAYAUTH_JWKS_URL` and
`RELAYAUTH_ISSUER`; contradictory settings and extraEnv overrides are refused.
The `legacy` chart mode preserves the existing explicit issuer behavior; it is no longer the default.
This selects backend behavior; chart checks do not prove the image's verifier.

Merged #364 also binds detail reads through `LOCKER_*`, with S3 static keys or
Pod Identity supported. Whenever `LOCKER_BUCKET` is supplied, upstream startup
requires `PIPELINE_ORG_FROM_PREFIX=true`; the bare root rule above still applies.
The chart enforces this before rendering: a `LOCKER_BUCKET` extraEnv entry must
be a nonempty literal with literal `PIPELINE_ORG_FROM_PREFIX=true` and
`PIPELINE_KEY_PREFIX=96bulls`. Missing/false flags, org-suffixed or other roots,
and valueFrom references for these three layout inputs refuse rendering.
Reader and ingest bucket literals reject surrounding whitespace. When both
services are enabled and the reader has a bucket, it must equal
`ingestEdge.locker.bucket`; uploads and canonical reads cannot name different
buckets in that assembly.
Transport and object-store settings remain explicit operator configuration via
the existing reader extraEnv/CA mounts, with credentials in Secret references.
No store, credentials, auth mode, image or reader is enabled in a profile here.

Readiness calls `/readyz`, not the always-200 `/healthz`: it requires an enabled
service and a database `SELECT 1`. It does not prove complete grants, schema,
Control reachability or MinIO functionality. Before enabling any pilot, qualify
the exact combined image/generation with native PG/TLS/MinIO upload, retries,
writer indexing, reader/search, compressed objects and auth refusal cases.
Helm/schema tests prove only this chart slot. No ar-lap operation is performed.
