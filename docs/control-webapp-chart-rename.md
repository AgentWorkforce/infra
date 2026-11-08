# Control and Webapp public chart names

This source change renames `relay-cloud-api` to `relay-control` and
`relay-dashboard` to `relay-webapp`, matching the source repositories
`AgentWorkforce/relay-control` and `AgentWorkforce/relay-webapp`.
The umbrella selection keys are now `components.control` and
`components.webapp`; child values live under `relay-control` and
`relay-webapp`. Supplying any of the four old keys fails the umbrella render,
including an empty map or a disabled component. They are never silently ignored.

This is separate from the five session-component names in infra #94. The
existing `RELAYHISTORY_*`, `SELFHOST_*`, `DASHBOARD_*` API/environment contracts,
internal Node package paths, database names, schemas, roles, Secret names and
public URL paths retain their existing meanings.

## Images and provider replacement

The new leaf-chart defaults name `ghcr.io/agentworkforce/relay-control` and
`ghcr.io/agentworkforce/relay-webapp`, with no default digest. A release owner
must publish or alias the reviewed image, then supply and verify the new
repository's index/native manifest, config, source revision and digest before
an operator selects it. A digest recorded for `selfhost-api` or
`relay-dashboard` is not evidence that it exists under another repository.

Real deployment profiles explicitly retain their previously verified image
repository and digest. The local Control builder and its historical receipts
also retain `agent-relay-kind/selfhost-api`. This change neither republishes nor
relabels any artifact. CI-only synthetic digests test rendering, not image
availability.

The self-host target removes RelayAuth and the standalone relayhistory-cloud
provider, while keeping session history through sessions-* (reads, search,
deletion and privacy controls). That cutover is dependency-gated: the composed
single-origin native service, Control-only auth, ingest, writer, detail routes,
privacy/deletion contract and compatible image/generation must land and be
qualified first. This naming change retains the current provider dependencies
and does not claim that cutover, a Desktop install, or upload-to-app acceptance.

## Existing releases: preserve identities before changing names

Changing a chart name can change both a Deployment's immutable selector and its
Service/DNS names. Never use `helm upgrade --reuse-values` with the old keys,
uninstall/reinstall to get the new names, delete a PVC, or reset the fixture.
Keep the same release name, namespace, database URLs, credential Secret names,
claim references, image coordinates and application origins.

First save the old release values and manifest privately. Translate only the
two root child-value keys and the two component-selection keys. Preserve the
entire operator override maps, including every Secret and image value; refuse
a file containing both the old and new form of a key. All explicit dependent
Service URLs and ingress backend names must continue to name the retained
Services. Render and inspect the full resulting release before any mutation.

For each renamed child, explicitly set:

- `nameOverride` to its old effective selector name (the old chart name when no
  override was supplied).
- `fullnameOverride` to its old effective resource fullname.
- Webapp `api.serviceName` and every dependent Control URL to the old Control
  Service name.

For the historical kind profile, the supplied
[identity overlay](../charts/agent-relay/upgrade/kind-control-webapp-identities.yaml)
keeps `relaycontrol` and `relay-app`, with selectors `relay-cloud-api` and
`relay-dashboard`. Layer it after translated old values. For addons, preserve
the old `relayflows` command's `relaycontrol` URL as well. This overlay only
expresses naming compatibility; it is not a migration or rollout approval.
Other releases must use their own observed resource identities, not the kind
example. A subsequent workload/Service rename needs a separate reviewed plan
for traffic, clients, selectors and rollback.

`kind-up` checks an existing owned cluster for old Control/Webapp Deployments
or Services before invalidating `ready.json`, preparing images or applying
resources. It refuses that layout. Its UID ownership check remains in force;
the naming check grants no permission to adopt another cluster. New fixtures
render `relay-control` and `relay-webapp`. No ar-lap operation was performed.

## Validation limits

The offline naming tests compare the compatibility overlay's complete set of
object names, Deployment selectors, pod selector labels, Service ports,
Ingress Service targets and PVC claim references against the old core/addons
renders at source `d8bbff820a6541593fa2e889cbf14e3aa1f0baa7`. They also check
new names, old-key refusals, unchanged real image coordinates and the causal
pre-mutation refusal. These checks do not prove seeded data survives a real
upgrade/rollback, qualify an image, or rerun the historical ar-lap 57/0/3 proof.
A live upgrade requires those separate receipts and operator authorization.
