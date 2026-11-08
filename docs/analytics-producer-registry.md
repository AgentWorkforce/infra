# Proposed analytics producer and event registry

**Status: source proposal, not a runtime allowlist or producer registration.**
No collector, adapter, credential, chart binding or event emission is enabled by
this document. The [adapter contract](analytics-adapter-contract.md) determines
coverage; the [collector interface](analytics-collector-interface.md) determines
the envelope, authority, privacy and delivery rules.

## Location and ownership

The source catalog lives in **AgentWorkforce/infra**, at
`docs/analytics-producer-registry.md`. Infra maintainers own this document and
coordinate changes; each component owner must review its proposed component ID,
native event mapping, scope and property allowlist before implementation.
Publishing a proposed row is not approval to implement or enable a port.

The collector implementation owner is **not yet assigned in this contract**;
infragrok coordinates that assignment. That owner must implement and test the
reviewed runtime catalog and producer-registration binding. The deployment
operator then binds a producer credential reference to one deployment/component
authority. Those are separate steps: no runtime registration API, configuration
format or credential exists merely because this source catalog names a producer.
Unknown or unapproved components/events must fail closed.

Registry changes that add data fields, alter attribution or broaden scope need
component and privacy review. Existing native event names can be preserved by
the reviewed projector; this document does not require replacing an existing
typed event port. Runtime consumers must not infer authority from caller-provided
body fields or accept every row of a draft document automatically.

## Required producer inventory

The following is the inventory from the adapter contract, not a claim that its
ports, adapters or event registrations are complete. Wire IDs and event mappings
remain owner-confirmed inputs unless an explicitly reviewed record says otherwise.

| Component | When coverage is required | Event registration status |
| --- | --- | --- |
| relaycontrol | Core and add-ons | Owner inventory/registration pending |
| Dashboard / relay-app | Core and add-ons | Owner inventory/registration pending |
| Relaycast | Core and add-ons | Existing typed `TelemetrySink` must be projected through a reviewed adapter; registrations pending |
| History | Core and add-ons | Owner inventory/registration pending |
| Pipeline writer, workers and reader | Core and add-ons | Component/credential granularity and event mappings pending owner review |
| Desktop and CLI | The corresponding client trace | Authenticated local gateway and event mappings pending; clients never receive producer credentials |
| Relayfile | **When enabled in add-ons**; absent from core | Proposed initial synthetic event below; new port implementation remains held |
| Flows | **When enabled in add-ons**; absent from core | Owner inventory/registration pending |

Collector health uses bounded operational counters and must not recursively emit
its own failures into this analytics stream. Temporary compatibility components
must have an explicit coverage/removal disposition before complete acceptance;
this inventory does not request new auth-service implementation work.

## Proposed Relayfile record

The Relayfile owner reported no existing typed product-event port at source
`731ea459`. The proposed `ProductEventSink` through `httpapi.ServerConfig` is a
new port, not a claim about current code. Its implementation priority remains
with the program/component owners; the first cofounder handoff prioritizes core.
The owner reviewed the proposed wire ID, event name, installation-only scope
and empty property allowlist against that inventory. This confirms those source
choices; it does not authorize the new port or create a runtime registration.

| Field | Proposed value / rule |
| --- | --- |
| Component | `relayfile`, owner-reviewed wire ID; enabled add-on only |
| Event | `relayfile.addon.enabled`, owner-reviewed proposed initial **synthetic transport-acceptance** event |
| Record status | **PROPOSED**; no active producer registration or accepted runtime kind |
| Event owner | Relayfile maintainers, coordinated by layered-relayfile |
| Scope | Installation-only; `tenant_id` and `workspace_id` are absent and must not be supplied |
| Properties | Empty strict allowlist (`{}`); no arbitrary fields, paths, names, content, tokens, credential hashes or exceptions |
| Identity | `component` and opaque `deployment_id` bound by the future producer registration; the body cannot override them |
| Envelope | Version `1`, fresh stable event ID, UTC occurrence time and opaque trace identity, following the collector interface; retries retain the event ID |
| Emission boundary | An explicit synthetic acceptance hook with the add-on enabled and collection explicitly configured; process startup alone must not emit it; preserve collection/privacy defaults |
| Destination | Default `none` when required collection inputs are absent; an explicitly configured self-host adapter uses the authenticated local collector, with no hosted fallback |

This first synthetic event can test producer-to-collector transport. It does not
prove a license was verified, storage is ready, a file was read/written, or the
complete correlated user-operation analytics trace passed. Further operation
events and their attribution require their own owner-reviewed registration.

## Deployment inputs still pending

Future chart/application integration must agree the opaque `deployment_id`, full
collector endpoint including `/v1/events`, per-producer Secret reference and
explicit destination selection. No raw credential values belong in this catalog
or Helm values. Relayfile at the reviewed source has neither deployment identity
nor analytics configuration; these are new chart-supplied inputs, not existing
environment wiring. Absent inputs select `none` and cannot trigger an event.
Collector producer registration, reviewed field projection,
authenticated client gateway and persistent single-writer collection remain
implementation/proof work. A documentation row or chart render is not admission
or durable ingestion evidence.
