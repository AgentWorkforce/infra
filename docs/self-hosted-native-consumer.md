# Native canonical consumer chart slot

`nativeConsumer.readerMaxRuleset` manages `READER_MAX_RULESET` for this
consumer. It defaults to `8` and accepts only `8`, `9`, or `10`. Raising it
requires a qualified image containing relayhistory-pipeline #489 at `94352d36`
or a reviewed successor; it does not enable the consumer or select writer
output. Stage reader compatibility first and retain the required ceiling on
rollback while newer objects remain.

`nativeConsumer` adds the merged pipeline #336
`SERVICE=session-pipeline-consumer` reconciler and an optional
`SERVICE=session-pipeline-consumer-bootstrap` Job. It is off by default; no
profile selects an image or enables it. This is chart plumbing for an accepted
canonical assembly, not upload/readback, history migration or privacy acceptance.
The initial assembly is TEST/PILOT only: product deletion/reset/privacy surfaces
remain unsupported. Publication, GC, hosted queues/fanout and buffered modes remain
absent. A native-origin router must return the native backend refusal for an
unsupported operation; do not leave a public legacy-History fallback to report
success against another database. This slot adds no routing.

The reconciler reads canonical manifests, stores pointers and writes the
Postgres search projection. It is terminal (`PIPELINE_FANOUT=off`) and uses one
replica with `Recreate`. Disable `worker.components.hoopdb-indexer.enabled`,
stop the installed old indexer, and only then record
`nativeConsumer.legacyIndexerDrained=true`. Different Deployment names do not
provide a drain barrier. Keep the database, object-store contents and backups.

## Required inputs

- A qualified image repository and immutable digest containing both SERVICEs
  and the matching migration generation. There is no default digest or tag.
- `config.existingSecret`/`config.key`: JSON `{hoopdb_url:<dedicated runtime
  URL>}`, with the genuine `search_consumer_runtime` login. No owner, reader,
  generic worker URL or ClickHouse block.
- Explicit `postgres.host`, `postgres.port`, `postgres.database`, public
  `caConfigMap`/`caKey` and pinned `caSha256`. Only the init container sees
  the public CA projection. After validation it freezes the public bytes in a
  memory volume; the running container sees that copy read-only at
  `/etc/native-consumer-postgres/ca.crt`, without the mutable projection.
- An explicit `backendId`, coverage floor `completeSince`, bare root
  `keyPrefix=96bulls`, and a lookback greater than the reconcile cadence.
  Do not backdate a coverage claim. With the reader enabled, its Postgres
  backend, image, floor, backend id and literal Locker/layout inputs must
  match. The enabled native ingest must share the composed image and store.
- S3/MinIO bucket/region/endpoint and a separate static credential Secret, or
  `locker.credentials.mode=podIdentity` with an explicitly selected service
  account. Pod Identity omits static keys; its agent injects the short-lived
  credentials URI/token file. The source validates that provider. This slot
  does not claim IAM binding or store authorization acceptance. GCS is not
  selected by this slot.

For in-cluster plain HTTP object storage, use a qualified Kubernetes Service
DNS origin and set `allowInClusterHttp=true`. Arbitrary HTTP hosts and paths
refuse. No `extraEnv`, `envFrom`, custom command or extra volume escape is
accepted; configuration and credentials stay managed.

## Both Postgres pools must verify TLS

The consumer's primary `supabasePool` uses the explicit pinned custom-CA
helper. Its worker/readiness pool uses `openHoopDb(HOOPDB_URL)`, which reads URL
TLS settings instead. The JSON URL must therefore contain exactly:

```text
?sslmode=verify-full&sslrootcert=%2Fetc%2Fnative-consumer-postgres%2Fca.crt
```

No other query parameter, duplicate TLS parameter, `options=`, fragment,
foreign role/host/port/database or alternate CA path is admitted. Do not put a
real URL/password into values or this document. `HOOPDB_URL` is not separately
rendered; the service derives it from the same runtime JSON.

The managed init contract verifies the CA bytes/hash/validity and freezes the
validated bytes before opening BOTH
production pool factories. It checks `pg_stat_ssl.ssl=true`, the actual
database and genuine configured login for each. It also runs the source
consumer role/schema/tenant-policy admission and normal exact-generation/PASS
readiness gate. It writes no SQL grants or marker. Its wait has a hard deadline,
per-connection/query bounds, and constant error codes that expose no credential
or URL. A helper-pool TLS success cannot qualify the second pool silently. A subsequent
ConfigMap update cannot change the generic pool's trust; a new init/rollout must
validate the new CA pin. An init retry refuses a different already-frozen CA.

## Active legacy services share the schema generation

Before migrating, stop incompatible legacy workers/ingest or qualify them
against the selected composed image. The old indexer always stays disabled and
drained. Other worker components may be disabled or scaled to zero; the legacy
`alleyoop` ingest may be scaled to zero. Every remaining active component must
resolve through its actual child-chart image helper to exactly the consumer's
repository and immutable digest, with no tag fallback. Both prepare and serve
refuse a mismatch.

Active legacy services also require `postgresCa.enabled=true`, the same public
ConfigMap/key as the consumer, and `nativeConsumer.legacyRuntimesQualified=true`
after operator validation. Their opaque HOOPDB_URL Secrets must name the intended
database and dedicated runtime role and use `sslmode=verify-full` plus
`sslrootcert=/etc/postgres-ca/ca.crt`. Verify the actual CA ConfigMap is immutable,
its bytes match the selected pin, the mounts are read-only, and genuine native
pool logins pass TLS, database/identity and exact-generation probes; wrong CA
and hostname must refuse. The legacy templates project the CA directly and do
not use this slot's frozen-copy init. The chart can verify image/reference
metadata but cannot inspect opaque Secret URL contents or prove these external
runtime checks. Keep those services at zero until their proof exists.

## Owner bootstrap and ordering

Use ordinary operator/driver phases, with the same image and trusted CA:

1. Apply and verify the official schema/role prerequisites and migrator for the
   selected database/generation. Preserve any historical ledger; an unsupported
   migration history must be repaired by its source owner, not this chart.
   Run the selected official driver a second time and verify it applies zero
   steps. Set `worker.migrations.enabled=false` and only then acknowledge
   `nativeConsumer.migrationDriverVerified=true`; this slot never starts a
   second, stale-image migration Job. These acknowledgements do not replace
   the runtime's actual generation/PASS admission.
2. If using the optional Job, set `bootstrap.enabled=true`, a DIFFERENT
   `bootstrap.existingSecret` containing owner JSON `{hoopdb_url:<owner URL>}`,
   and its explicit `ownerRole`. Keep `bootstrap.phase=prepare`: this renders
   the content-addressed Job and public contract only, with no consumer
   Deployment. The Job has no hooks, no API token and `backoffLimit=0`.
3. Wait for successful Job completion and preserve the result. The official
   bootstrap owns its transaction, advisory lock, schema/policy creation and
   exact consumer grants/verification. Its source must admit this schema
   owner and role-creation authority. An unsupported owner fails; the chart
   does not grant CREATEROLE, SUPERUSER or substitute a different authority.
   The isolated TLS helper's owner fixture is `postgres`; it does not qualify
   first role promotion by an existing non-superuser schema owner. That path
   needs its own source-owned proof before enabling this Job.
4. Provision the dedicated runtime password through the supported operator
   step AFTER its NOLOGIN-to-LOGIN promotion; inject only its runtime JSON
   Secret. A preset credential before promotion may be refused by source.
5. Select `bootstrap.phase=serve` and apply the Deployment. The unchanged Job
   spec retains its name. The bounded init checks actual runtime readiness
   before the main process starts. If the Job is managed separately, leave
   `bootstrap.enabled=false`; the same init barrier is still required.

Changing the Job's actual image, CA, target, owner Secret/key, backend/floor or
other pod inputs changes its name. Capture prior Job evidence before an upgrade.
Helm rendering is not proof of Job completion, owner authority or runtime
acceptance. There is no automatic password, SQL grant or cloud resource action.

Readiness calls the real `/readyz`, requires the enabled flag and a non-dormant
successful JSON answer, and refuses the consumer's own unhealthy marker.
Liveness checks `/healthz` with the same owned marker. Probes are internal; this
slot creates no public Service/Ingress. Schema/probe success must still be
followed by native TLS negative controls, real S3/MinIO authorization and a
fresh upload -> canonical object -> pointer/search -> reader -> dashboard trace.
The render-only CI fixture is synthetic and must never be installed.

## Isolated contract proof

The optional local proof uses cached, immutable service and PG17 images and
creates only a disposable local Docker fixture. It runs the official schema
chain and consumer bootstrap, proves both real pool factories use verified TLS,
and refuses a wrong hostname, wrong CA pin and correctly pinned unrelated CA.
Private test CA keys remain in container tmpfs and are destroyed on exit; no
project credentials, kubeconfig or object store are used.

```sh
python3 ci/sessions-pipeline-native-consumer/native_tls_proof.py \
  --image '<qualified cached services repository@sha256:digest>' \
  --receipt /tmp/native-consumer-tls-proof.json
```

This synthetic schema/TLS proof does not qualify a release image, existing
database upgrade, object-store writes, IAM, privacy controls or dashboard
visibility. Repeat it against the final image and complete the real acceptance
trace before selecting the slot in an installation.

## Reader composition after chart extraction

Use the standalone `sessionReadApi` dependency, not the removed `readApi` key.
The native consumer requires its enabled reader to use the same qualified image,
Postgres backend ID, explicit coverage floor, pinned public custom CA ConfigMap
and canonical Locker layout. Keep `PIPELINE_KEY_PREFIX=96bulls` and
`PIPELINE_ORG_FROM_PREFIX=true` as literal adapter settings; configure the backend
ID through managed `sessionReadApi.search.backendId`. The owner bootstrap Secret
is Job-only, including after the Job is disabled. The independent `searchIndexer`
must stay disabled to preserve one canonical/search writer.

For Control-issued workspace tokens, select `sessionReadApi.auth.mode=relaycontrol_only`,
its existing introspection Secret and base URL, and leave RelayAuth issuer/JWKS
empty. Configure PostgreSQL through `postgres.tlsProfile=custom-ca` and
`postgresCa`, rather than the now-reserved TLS environment variables. Sync login
uses `sessionReadApi.login.advertisesSync=true` only when the same-origin ingest
service is qualified. The separately supported self-issued reader mode is not
enabled by this consumer chart or its install fixtures.
