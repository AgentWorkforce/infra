# Chart rename compatibility and upgrade map

Status: preparation only. The requested public names are `locker` →
`session-object-storage` and `alleyoop-ingest` → `session-ingest-api`.
The exact package/values-key versus Service/display-name implementation boundary
still needs confirmation. No chart is renamed, no release is upgraded, and no
fixture state is changed by this inventory. Public names do not automatically
rename data-bearing Kubernetes objects, SQL schemas or internal pipeline commands.

## Requested name map

| Current public name | Requested public name | Source boundary / upgrade requirement |
| --- | --- | --- |
| `locker` | `session-object-storage` | MinIO dependency/value alias and separate kind storage release. Preserve its existing StatefulSet/claims and legacy Service DNS; do not move or replace stored objects to obtain the name. |
| `alleyoop-ingest` | `session-ingest-api` | Ingest chart/workload identity, currently backed by Service `alleyoop`. Keep internal `SERVICE=alleyoop-ingest`, existing routing and stage entrypoints unchanged. |

Control, dashboard and parent pipeline package renames are not inferred from
this two-name request. They appear below only because their bindings/callers are
part of the baseline that must remain stable.

An additive public Service/display alias is distinct from a Helm package,
dependency alias or workload rename. The source implementation must specify which
identities change and how old/new values and DNS names behave. Existing overrides
must not silently disappear when a dependency key changes. A storage rename must
not create empty replacement claims; stage names must not be changed by a global
text replacement. Until that boundary is agreed, the inventory remains a plan.

## Baseline and compatibility identities

Source: infra `91c9b7981d706969cd19dc7fab09f9fddb646959`, chart tree
`2dbd3f63351b6e831b030abb1bdbeaf21b1bd06a`. Static renders contain 35 core objects
and 43 add-on objects. The [identity baseline](../ci/chart-rename/identity-baseline.json)
records object keys, selectors, PVC references/specs, image pins, SERVICE values
and hashes of container commands/arguments. It uses checked-in values only, not
private installation state. It is not an executed upgrade/data-survival receipt.

| Source package/key | Existing identity to preserve | Rename risk |
| --- | --- | --- |
| `agent-relay` release | Existing release name and namespace; kind uses `agent-relay` / `agent-relay` | A new release is not an in-place rename. |
| `relay-cloud-api` | Kind object/DNS `relaycontrol`; selector name `relay-cloud-api`; instance `agent-relay`, component `api` | `fullnameOverride` does not preserve the separate selector-name helper. |
| `relay-dashboard` | Kind object/DNS `relay-app`; selector name `relay-dashboard`; instance `agent-relay` | A new Chart.Name can change both default names and immutable selectors. |
| `sessions-pipeline` | Umbrella values key and `components.sessionsPipeline`; child aliases `worker`, `alleyoop`, `hoopdb`, `locker`, `otel` | Changing a dependency name without an alias/values migration can silently drop settings. |
| Pipeline workers | `sessions-hoopdb-indexer`, `sessions-bob-costas`, `sessions-referee`; selector name `worker` | Internal aliases and stage identities are separate from the parent package name. |
| Ingest | `alleyoop-ingest` Deployment, `alleyoop` Service; existing component/instance labels | Renaming the product/package must not alter callers or stage commands. |
| Persistent claims | `relaycast-data`, `relayauth-data`; add-ons also `relayflows` | New names must not create empty replacement claims or orphan current volumes. |
| Kind platform storage | Separate `postgres` StatefulSet/Service and `kind-locker` Helm release | Their resources are created outside the umbrella render; preserve their actual PVC/PV bindings separately. |
| CNPG/MinIO profiles | Existing Cluster/release names and generated claims | These are not enabled in the kind umbrella baseline and need their own upgrade coverage. |

The final implementation map must identify each source directory, package name, dependency
entry/alias, values key, condition, repository/index/archive reference and version.
Do not infer that changing documentation display names authorizes changing any
of those identities. The existing strict chart version-bump policy still applies.

## Proposed compatibility rules

- Keep the same Helm release and namespace. Do not uninstall/reinstall, reset
  kind or delete/recreate PVCs as a rename mechanism.
- Preserve existing resource names, Service DNS, workload selectors and pod
  labels. Non-selector chart/version metadata may change. Standalone installs
  and umbrella installs both need coverage: kind's explicit fullname overrides
  must not conceal a broken standalone default.
- Preserve existing dependency aliases/values behavior or provide a reviewed
  translation with deterministic precedence and refusal of conflicting old/new
  settings. An alias is a compatibility choice, not merely a display label.
- Preserve Secret references and key names, database/schema/role bindings,
  ServiceAccounts/RBAC, network-policy selectors, ingress backends, storage class,
  claim retention and volume mounts. The rename must not broaden authority or
  change a backend/image along with its packaging identity.
- Keep internal container SERVICE/stage commands, module/CLI entrypoints,
  migrations and object-store keys unchanged. In particular, package renaming is
  not a `sessions` SQL-schema migration or a pipeline stage rewrite.
- Ordinary template-hashed Jobs can receive new recipe-derived names, but their
  migration semantics, barriers and idempotency must be proved. No Helm hook or
  manifest/ACL bypass is introduced to get an upgrade through.
- Keep current profiles, legacy auth settings and default-off reader/add-on
  gates. A package rename does not qualify the pending PG, entitlement or
  pipeline-to-app runtime contracts.

## Upgrade evidence required before promotion

1. Render both kind profiles, standalone control/app fixtures and the relevant
   CNPG/external-database pipeline profiles before/after the confirmed rename.
   Compare stable identities and classify only explicitly allowed metadata/Job
   changes. Run existing schema, golden, dependency, registry and version checks.
2. On a separately owned local fixture, seed real control/session records,
   Cast messages and object-store content, recording resource/PVC/PV identities
   and data hashes. Upgrade the same release; do not reset ar-lap for this test.
3. Verify stable selectors and Service routing, attached original claims, runtime
   LOGIN/ACL readiness, data readback, sign-in, message and session paths. Restart
   the upgraded workloads and verify again. A ready pod or render diff is not
   a data-survival proof.
4. Exercise supported rollback with compatible image/schema floors and the same
   claims. Refuse incompatible rollback rather than restoring a misleading
   healthy state. Preserve failed evidence and document any maintenance window.

Only the baseline inventory has run. Public targets are recorded; the exact
packaging/alias boundary, rename implementation, post-change renders and live
upgrade/rollback proof remain pending. The running
ar-lap fixture, its CA/tenant/operator tools and its existing data remain untouched.
