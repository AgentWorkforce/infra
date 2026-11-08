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
equal the reader's `READ_API_ORIGIN`; rendering refuses unequal `readApi.origin`
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
merged pipeline #364 (`8a075b26`), select `readApi.auth.mode=relaycontrol_only`,
enable `readApi.auth.relaycontrol.enabled`, supply its URL and Secret reference,
and clear both `readApi.auth.relayauth` fields. The chart emits
`READ_API_AUTH_MODE=relaycontrol_only` and omits `RELAYAUTH_JWKS_URL` and
`RELAYAUTH_ISSUER`; contradictory settings and extraEnv overrides are refused.
The default `legacy` chart mode preserves the existing explicit issuer behavior.
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

## Admission modes

`ingestEdge.admission.mode` defaults to `sync`. It preserves the existing
request path and HTTP probes, emitting no admission-mode environment variables.
The ingest edge itself remains disabled by default in every profile.

The `async` and `drain` modes require the self-host admission implementation
from pipeline [#398](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/398).
That runtime is still under review; this chart supplies configuration and does
not qualify an image or enable a deployment. After that implementation lands,
qualify an immutable combined image before selecting either mode:

```yaml
ingestEdge:
  admission:
    mode: async
    concurrency: 4
    scanIntervalMs: 15000
    maxAttempts: 20
```

In `async`, a successful upload acknowledges a create-only object-store inbox
write with the queued admission receipt. The in-process consumer performs
database admission afterward. A queued receipt does not mean the session is
already indexed, rendered or searchable. Object-store failure refuses the
upload; it must not silently fall back to synchronous admission. The configured
store must pass the runtime's conditional-write startup check.

Async and drain need object listing as well as the existing read/write access.
At the pinned draft runtime, the consumer scans both `96bulls/.admission-inbox`
and `96bulls/.admission-dlq`; an upload-only credential is insufficient. Scope
listing to the runtime's required prefixes, and retain access for its privacy,
outcome and startup-probe operations. The startup probe verifies conditional
create and compare-and-swap, reads the result and attempts cleanup. Use the
final runtime's permission contract when qualifying credentials; this chart
does not grant storage permissions or broaden an existing policy.

In `drain`, new uploads use synchronous admission while the consumer continues
processing the existing inbox. Use this explicit mode to drain queued work
before returning to `sync`; a chart rollback alone does not empty the inbox.
Do not remove or repurpose its bucket while queued work remains.
These two modes additionally serve `GET /v1/delivery/admission`, an authenticated
object-store status read using the caller's verified tenant identity. Any public
router must admit that exact path deliberately; this chart adds no route.

The managed values map to `SELFHOST_INGEST_ADMISSION`,
`SELFHOST_ADMISSION_CONCURRENCY` (1–32), `SELFHOST_ADMISSION_SCAN_MS`
(1000–600000 milliseconds) and `SELFHOST_ADMISSION_MAX_ATTEMPTS` (1–100).
Retries that reach the limit become dead letters; inspect and recover them
through the runtime's supported operational procedure. The chart supplies no
dead-letter deletion or replay command.

Async admission removes admission SQL from the upload request path. Every
request still uses Control introspection with no positive cache, and startup
still verifies the PostgreSQL role and TLS connection. This is not a promise
of database-independent authorization or startup.

In sync mode, `/readyz` requires an enabled service and a database `SELECT 1`.
Async and drain use an exec probe that requires HTTP 200, `ok:true`,
`enabled:true`, the exact configured `admission` mode, and healthy `consumer`
status with valid backlog, dead-letter and scan-age counters. An older image
that ignores the mode fails readiness. Async readiness follows the inbox
consumer; drain also requires the synchronous database check. Liveness remains
`/healthz`, so a dependency outage removes readiness without creating a restart
loop. None of these checks proves complete grants, schema, Control reachability,
eventual admission or end-to-end object-store functionality.

Before enabling any pilot, qualify
the exact combined image/generation with native PG/TLS/MinIO upload, retries,
writer indexing, reader/search, compressed objects and auth refusal cases.
For async, also prove database failure after startup still yields a durable
queued receipt, restart/retry recovery without duplicate admission, dead-letter
visibility, and successful readback after recovery. Helm/schema tests prove
only this chart slot; this source change performs no runtime operation.
