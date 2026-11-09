# Descriptive session chart and workload names

This change implements the names recorded in infra #92. It changes real chart
metadata, dependencies and rendered Kubernetes resources. It does not change
application images, database migrations or internal engine entrypoints.

| Component | Operator-facing name | Implementation |
| --- | --- | --- |
| Session object storage | `session-object-storage` | MinIO dependency alias, default Deployment, Service and PVC names |
| Session ingestion | `session-ingest-api` | Real chart at `charts/session-ingest-api`, plus Deployment and Service |
| Session summaries | `session-summary-worker` | Deployment in `sessions-pipeline-worker` |
| Session metadata indexing | `session-metadata-indexer` | Deployment in `sessions-pipeline-worker` |
| Session status updates | `session-status-worker` | Deployment in `sessions-pipeline-worker` |

Default worker Deployment names are scoped by the chart fullname; the local
kind profile explicitly pins the five short public names. Each worker accepts
`components.<internal-stage>.fullnameOverride` for an explicit identity.
Different standalone releases retain separate defaults and fullname overrides.

The three workers still share a chart; they are not three new chart packages.
The engine still selects `bob-costas`, `hoopdb-indexer`, `referee` and
`alleyoop-ingest` through `SERVICE`. Storage adapter environment names and
credentials are unchanged. `alleyoop` remains the parent chart's compatibility
values alias for the renamed ingest package. Existing worker component keys
remain internal configuration references.

New installs use `sessions-pipeline` 0.7.0 (`sessions-pipeline-worker` 0.7.0 and
`session-ingest-api` 0.4.0), or umbrella `agent-relay` 0.4.0. The third-party MinIO
chart stays at its pinned version; its dependency key becomes
`session-object-storage`. Old root-level `locker` dependency values fail with a
migration message rather than being silently ignored. Per-service
`worker.locker` and `alleyoop.locker` adapter settings retain their meaning.

## Existing installations

Do not use `--reuse-values`: export and review the complete existing values,
move the old MinIO `locker` block to `session-object-storage`, and retain its
storage, existing-claim, credential, Service and DNS settings. This source change
does not authorize a live rename or establish data survival across an upgrade.

To retain existing resource identities while adopting the new chart package,
set these compatibility values inside the `sessions-pipeline` block of the
umbrella (or at the root for the pipeline chart):

```yaml
worker:
  legacyResourceNames: true
  # Retain your existing fullnameOverride/nameOverride.
  locker:
    endpoint: http://locker:9000 # the former default; keep yours if it differs
alleyoop:
  legacyResourceNames: true
  # Retain your existing fullnameOverride/nameOverride.
  locker:
    endpoint: http://locker:9000 # the former default; keep yours if it differs
session-object-storage:
  fullnameOverride: locker
  nameOverride: locker
  # Copy the rest of your existing MinIO values here, including persistence.
```

The two storage overrides above describe the former default; use the actual
recorded names if the old release overrides them. The upgrade check recognizes
only `locker`, so recorded names other than `locker` must also set
`acknowledgeStorageRename: true`; never pin `locker` on such a release, because
Helm would prune its real claim. Identity render tests verify
that these values still reference the original PVC. They do not create, delete
or inspect a real volume.

`helm upgrade` refuses a release that uses in-chart MinIO with the default
`session-object-storage` name, because Helm would otherwise remove
`PersistentVolumeClaim/locker` and create an empty claim. Set both storage
overrides above to keep it. Do not use `persistence.existingClaim: locker` for
a claim the release created: no PVC is rendered, so Helm still deletes it unless
the live claim is first annotated `helm.sh/resource-policy: keep`. Set
`acknowledgeStorageRename: true` only for a release installed at 0.7.0 or later,
one whose objects are disposable, one whose claim already carries that
annotation, or one pinned to its recorded non-`locker` names as above. The check needs a real upgrade: it does not run under `helm template`
without `--is-upgrade`, so manifest-based pipelines must apply these values
themselves.

The Terraform examples retain both default ingest identities,
`<release>-alleyoop` and `<release>-session-ingest-api`, through the cutover.
These are defaults, not a substitute for inspecting the installed Deployment's
`spec.template.spec.serviceAccountName` and rendering the proposed chart with the
operator's values. `fullnameOverride`, `nameOverride` and `serviceAccount.name`
can change that identity. Keep every actual old and new ingest ServiceAccount
in the root's IAM bindings until its workload is drained; removing the legacy
principal is a separate deliberate change after verifying object-store access.
The foundation output retains the legacy `alleyoop` field and adds
`session_ingest_api` for the new default.

Worker upgrades also refuse descriptive names unless
`worker.legacyResourceNames: true` retains the old names, or
`worker.acknowledgeWorkloadRename: true` explicitly confirms that the old indexer
has been stopped. For a standalone worker chart these keys are at its root.
Persist the acknowledgement for releases already installed with descriptive
names. A storage pin alone does not stop two differently named indexers from
overlapping; `Recreate` only coordinates replicas of the same Deployment.

A live move to descriptive resource names requires a separate controlled
cutover: stop the old indexer before creating its replacement (Deployment
`Recreate` does not coordinate two differently named Deployments), preserve the
old storage claim explicitly, update DNS consumers, and verify seeded data and
rollback before removing old resources. Do not delete a PVC to make the rename
work. The current running QA installation is not renamed by this PR.

The local `kind-up` driver refuses existing `kind-locker` resources before
invalidating readiness or changing resources. It never adopts a differently
named Helm release or silently switches an existing installation to an empty
claim. Preserve the old release and complete a reviewed data-preserving cutover
before rerunning the new recipe.

## Reconcile a completed local kind cutover

`reconcile-names` is an explicit import of an already-completed operator
cutover. It does not rename resources, stop workloads, apply migrations, change
Secrets, move data, adopt a release, or turn a live UID into ownership authority.
The existing versioned cluster ownership and original readiness receipts must
already bind this checkout's selected `core` or `addons` profile and native
cluster UID. A completed core cutover cannot authorize an addons fixture.

The private cutover packet must retain these files together:

- `activation-receipt.json`: `PASS`, phase `CLIENT_WRITERS_RESUMED`, distinct old
  and new Deployment UIDs, original PVC UID, one-writer confirmation, unchanged
  image/PVC confirmations, equal nonempty seeded inventories, and the synthetic
  sentinel key/content hash. A failed, partial, or rolled-back attempt refuses.
- `before-inventory-normalized-private.json` and
  `after-inventory-normalized-private.json`: equal sorted object rows containing
  `key`, `size`, `etag`, and `versionId`, whose content hashes and totals match
  the activation receipt. The sentinel must be one of these objects.
- `render-review-receipt.json`, `values-before.json`, and `minio-5.4.0.tgz`: the
  review binds the same chart/values bytes and exactly two changed fields,
  `Deployment.metadata.name` and `Deployment.spec.template.metadata.name`.
  The original `locker` PVC, Services, selectors, Secret references, image and
  mount path remain in the same `kind-locker` Helm release.

Keep this packet under the checkout's private `.kind` directory. Never invent
a receipt to silence an upgrade guard, or use `persistence.existingClaim` to
remove the release-owned PVC from the manifest. The currently installed release
must still render that PVC and the named Deployment. Readback verifies every
seeded object and the sentinel against the live store; additional later objects
are allowed. A missing/changed seed, replaced claim, duplicate writer, foreign
release, configuration drift, or missing original readiness anchor refuses.

For a locally built Control image, also retain its native OCI archive. The local
Docker tag must still export the same native manifest/config; reconciliation checks
that export before changing readiness or selection metadata. If the tag is missing
or was rebuilt, restore the verified archive first; reconciliation does not
silently replace the host cache. Admission
checks the archive's manifest/config bytes, platform and approved source, pairs
the API/migration entrypoints, and compares the selected image and rendered
application configuration with the live named Deployments. An old build receipt
alone cannot qualify a different image.

```sh
make kind-reconcile-names PROFILE=core \
  CUTOVER_RECEIPT=.kind/operator-cutover/activation-receipt.json \
  CONTROL_IMAGE_ARCHIVE=.kind/operator-cutover/native-control.tar
make kind-up PROFILE=core
make kind-proof-core
```

For an independently qualified addons cutover, select `PROFILE=addons` and the
existing owner-supplied `KIND_LICENSE_FILE` as usual. Its installed component
selection and credentials must match that profile; this path does not relax
licensing or add-on acceptance gates.

Reconciliation writes a typed private `named-layout.json` binding. It archives
the original `ready.json`, images/build metadata, values, render and proof under
a new `named-history-*` directory, imports the **current installed** application
values, and selects the verified Control archive metadata. It clears stale
active readiness/images; the old proof remains untouched and historical. A
later qualified public-origin change is retained rather than replaced with the
values from the earlier storage cutover. Only a complete subsequent `kind-up`
can issue current readiness, and only a fresh proof can establish acceptance.
Required application Deployment names come from the selected render rather than
the previous implementation's fixed worker list. The default legacy profile
still requires every selected role. Disabling the legacy metadata indexer is
accepted only with an explicitly selected, drained native-consumer runtime
replacement; a preparation-only Job, owner bootstrap role, missing selected
Deployment, or remaining legacy indexer refuses.

On reuse, `kind-up` rechecks the typed binding, original readiness archive,
storage/Postgres identities and specifications, seeded readback, selected
values and credentials **before** invalidating readiness or preparing images.
It keeps the original storage release/claim and applies the saved naming
transform automatically with Helm 3 or the isolated Helm 4 postrenderer plugin.
It preserves the existing Postgres server configuration (including reviewed
TLS), and compares credential projections without replacing Secrets or dropping
extra keys. It still executes the ordinary ordered role/schema checks. Tenant
annotation updates remain retryable across interruption; they cannot select a
different application image through this reconciliation path.

If an interrupted operation left no active readiness file, reconciliation
requires the independently retained anchor explicitly:

```sh
python3 ci/agent-relay/kind/stack.py reconcile-names --profile core \
  --cutover-receipt .kind/operator-cutover/activation-receipt.json \
  --control-image-archive .kind/operator-cutover/native-control.tar \
  --readiness-anchor '.kind/core/named-history-<recorded-id>/ready.json'
```

The anchor must come from that profile's preserved naming history; a guessed
live UID or another profile's file refuses. Credential/PKI rotation or a
Postgres server/Secret change also needs explicit requalification. This path
reuses the selected valid TLS identity rather than silently reissuing it.

Fresh installations keep their ordinary layout and need no cutover receipt.
An unqualified legacy fixture still refuses. No cloud operation, fixture reset,
or live rollout of this reconciliation implementation is implied by its source
tests or by the earlier operator cutover evidence.
