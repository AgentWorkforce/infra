# Self-host analytics collector interface

This defines the source implementation target for the
[analytics adapter contract](analytics-adapter-contract.md). No application,
collector, chart, volume or gateway is implemented or enabled by this document.

## Placement and adapters

One collector Service inside the installation owns the persistent, rotated
NDJSON export. Server components send batches through their analytics adapter;
they do not need an analytics PVC each. The collector's files are an export,
separate from the single RDS application database. An application-local file or
`emptyDir` may be a bounded spool, but is not durable collector acceptance.

A producer exposes its existing typed event port where suitable. `capture`
enqueues bounded asynchronous work; it does not await export on the product
request. A deadline-bounded `flush` supports tests and shutdown. A destination
factory selects `none`, `collector` or `posthog` from explicit configuration.
Preserve existing collection/privacy defaults. The acceptance fixture must
explicitly select the collector and demonstrate an event from every component.

In self-host mode the collector adapter is the file destination. It requires
an installation-local endpoint and a producer credential reference. It never
switches to PostHog on error. The hosted adapter targets `https://i.agentrelay.com`
with the hosted project configuration; no hosted key or endpoint default is
injected into self-hosted workloads. No live hosted configuration is changed here.

## Internal batch endpoint

The collector exposes an authenticated, internal `POST /v1/events`. Browser
and Desktop clients do not receive collector producer credentials or connect
directly to this Service. A separate authenticated local gateway validates
their existing application session/token, derives tenant/workspace authority,
and invokes the producer port. It must not trust caller-supplied authority or
repurpose the operator telemetry issue/export endpoints as analytics intake.

The batch body is a JSON object with `schema` equal to
`agent-relay.analytics.batch/v1` and an `events` array. Each event contains:

| Field | Meaning |
|---|---|
| `version` | Event envelope version, initially `1` |
| `event_id` | Stable producer-generated identifier, retained across retries |
| `occurred_at` | UTC event occurrence time |
| `component` | Registered producer component |
| `deployment_id` | Opaque installation/deployment identity |
| `event` | Registered event kind |
| `trace_id` | Opaque correlation identity for the user trace |
| `properties` | Versioned, event-specific allowlisted properties |

Existing native observations are projected into this envelope. The producer
registration binds component and deployment identity; body fields cannot
override that binding. Tenant/workspace attribution is exported only through
the reviewed projector after application authorization. Initial tests use
synthetic/install-scoped identity; this adds no new user identity collection.

Authenticate with a per-producer credential supplied through a Secret
reference. The collector verifies it against its producer registration. Do not
reuse a database, runtime user, Desktop session or migration credential.
Helm wires the endpoint and Secret references; transport/TLS/CA and network
policy must match the reviewed deployment profile. The Service is not a public
ingress, and analytics does not create hosted egress in self-host mode.

## Limits, delivery and privacy

The first implementation must publish finite configurable limits for batch
bytes/event count, individual event bytes, producer queue bytes/count, request
deadline, retries, shutdown flush, file size, file count and total disk use.
Validate the actual streamed body size, not only `Content-Length`. Reject
oversized/invalid/unauthorized batches before writing their records. Tests
must exercise each configured bound rather than assume unlimited memory/disk.

Return success only after the accepted NDJSON records have been appended and
flushed to the collector's persistent storage. Do not acknowledge an in-memory
queue as durable export. Disk-full/backpressure returns an explicit failure;
producers bound retries and report drops without failing product operations.
Delivery is at least once: stable event IDs make retries identifiable, but no
exactly-once or automatic deduplication guarantee is implied.

Both producer and collector project a typed field allowlist. A private-key
regex alone is insufficient. Never export credential hashes, tokens, raw
requests, product content, sender names or arbitrary exception context/stack.
Exception events need their own scrubbed allowlist. An existing internal
credential-proof hop remains distinct from analytics and cannot be forwarded
to this endpoint or PostHog. Operational telemetry retains its separate report,
signature, consent/defaults and outbox contract.

Collector health reports bounded queue/write/drop counters without recursively
emitting its own failures into the event stream. Acceptance requires a real
correlated event trace, restart/rotation and disk-full tests, producer failure
isolation, unauthorized producer/tenant tests, and proof of no hosted export
request in self-host mode. A health HTTP 200 or successful chart render is not
that proof.
