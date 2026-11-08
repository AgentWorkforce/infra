# Analytics adapters for hosted and self-hosted installations

User direction, 2026-11-07: every application component emits analytics through
an adapter. Self-hosted deployments write to a customer-local file collector;
hosted deployments write to our PostHog at `https://i.agentrelay.com`.

## Producer and destination boundary

Business logic emits typed domain events through its existing analytics port
where one exists. For example, Relaycast already exposes `TelemetrySink.capture`.
The deployment supplies the destination adapter; business logic does not select
PostHog or manipulate output files. A producer may keep its native event model:
the adapter projects it into the versioned export envelope.

| Deployment | Adapter | Destination |
|---|---|---|
| Self-hosted | File-collector adapter | Local/in-cluster collector, with file-backed NDJSON export |
| Hosted | PostHog adapter | `https://i.agentrelay.com`, with the correct hosted project configuration |

Self-hosted analytics must work without registering with the hosted service or
receiving a cloud API key. It must not fall back to the hosted destination on
collector failure. Browser/Desktop producers need an appropriate authenticated
local gateway or collector path; they cannot assume access to an in-cluster
Service or a server filesystem. Hosted project keys remain in the appropriate
server/client configuration contract; no credentials belong in Relay messages,
Helm values, Terraform outputs or exported events.

The installation uses **one in-cluster collector Service that owns the durable
NDJSON files**. Server adapters POST events to that Service; they do not each
mount an analytics PVC. A direct file writer is a collector implementation or
an optional development adapter, not the production producer contract. See the
[collector interface](analytics-collector-interface.md) for batching,
authentication, persistence and gateway boundaries. This clarifies the file
destination; it does not claim a collector implementation exists.

A common export envelope needs a version, stable event identifier, UTC occurrence
time, component and deployment identity, event kind, correlation/trace identity,
and explicitly permitted properties. Existing native event names can remain.
Export projectors must allowlist fields: Relaycast observations, for example,
contain an internal credential hash which must never reach either destination.
Product content, raw requests and tokens are not analytics properties.

Analytics is bounded asynchronous work. Define buffer/batch limits, bounded
retry/shutdown behavior and visible failure/drop counters. An unavailable sink
must not turn a successful product operation into a failure or create an
unbounded in-memory backlog. A no-op sink remains useful in tests, but does not
satisfy analytics acceptance.

## Component coverage

The producer inventory includes control, dashboard/relay-app, Relaycast,
History, the pipeline writer/workers and reader, Desktop/CLI, plus Relayfile and
Flows when enabled. Each owner must name its event interface, destination
factory, configuration/Secret references and at least one real event in the
complete user trace. Collector health also needs observable failure counters;
it must not recursively feed its own failures back into the same analytics loop.

Current inspected infrastructure does **not** establish complete coverage:

- Relaycast has the typed `TelemetrySink` boundary and Node/actor injection, but
  defaults to a no-op sink without a supplied adapter.
- Control's existing `telemetry.transport=file` keeps signed reports in an
  outbox for operator export. That is not proof of a live per-component product
  analytics file collector.
- The optional pipeline OTel collector defaults to `nop` exporters. Enabling it
  alone drops telemetry; its debug exporter also does not prove file collection.
- Other producer/destination bindings require owner inventory and runtime proof.

Use those existing seams where suitable. Do not rename an operator health
report or an OTel debug log as product analytics merely to claim coverage.

## Collector and deployment requirements

The self-host collector stays inside the installation's network boundary and
writes bounded, rotated files on a declared persistent location. State/retention,
access control, restart behavior, file format and disk-full handling need explicit
configuration. This telemetry export is distinct from the single authoritative
RDS application store. The hosted adapter explicitly uses our PostHog endpoint;
self-hosted network policy must not allow that destination for analytics.

Helm selects supported adapters and wires references/endpoints. Application
images must actually consume the selected settings; introducing a chart variable
alone does not implement an adapter. Metrics/traces may use their own established
observability pipeline, while product events retain their event/destination
contract.

## Acceptance

1. Run one correlated user trace through every enabled component. Identify each
   expected event and verify its component, tenant/workspace attribution and
   correlation identity without exporting internal credentials or product text.
2. In self-hosted mode, inspect the resulting collector files, restart the
   collector, verify retained records/rotation and failure counters, and prove
   producers make no hosted PostHog export request.
3. In hosted mode, inspect the synthetic events in the intended PostHog project
   at `i.agentrelay.com`; a successful HTTP health check is not event ingestion
   proof. Use approved test credentials without printing them.
4. Exercise an unavailable collector/PostHog endpoint and disk exhaustion in an
   owned fixture. Product behavior remains available, buffers stay bounded and
   drop/export failures are observable.

This document records the requested contract and inspected gaps. It does not
claim the collector, all component adapters or their runtime proof are implemented.
