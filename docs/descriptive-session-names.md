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
recorded names if the old release overrides them. Identity render tests verify
that these values still reference the original PVC. They do not create, delete
or inspect a real volume.

`helm upgrade` refuses a release that uses in-chart MinIO with the default
`session-object-storage` name, because Helm would otherwise remove
`PersistentVolumeClaim/locker` and create an empty claim. Set both storage
overrides above to keep it. Do not use `persistence.existingClaim: locker` for
a claim the release created: no PVC is rendered, so Helm still deletes it unless
the live claim is first annotated `helm.sh/resource-policy: keep`. Set
`acknowledgeStorageRename: true` only for a release installed at 0.7.0 or later,
one whose objects are disposable, or one whose claim already carries that
annotation. The check needs a real upgrade: it does not run under `helm template`
without `--is-upgrade`, so manifest-based pipelines must apply these values
themselves.

The Terraform examples bind object storage to `<release>-session-ingest-api`.
A release that keeps `legacyResourceNames` still runs as `<release>-alleyoop`, so
change `"session-ingest-api"` to `"alleyoop"` in that root's ServiceAccount list
before applying. For a cutover to the new name, list both until the old workload
is gone, or ingest loses storage access during the switch.

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
