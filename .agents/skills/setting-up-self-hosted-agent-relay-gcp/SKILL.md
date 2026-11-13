---
name: setting-up-self-hosted-agent-relay-gcp
description: Guides and verifies a customer-owned self-hosted Agent Relay installation on GCP using the agent-relay Helm umbrella chart, GKE, Cloud SQL, GCS, Relaycast, Sessions Pipeline with native History (read API and ingest edge), the control-plane API, Dashboard, and Agent Relay Desktop. Use whenever planning, installing, upgrading, recovering, or validating this GCP self-hosted suite.
license: Apache-2.0
compatibility: Requires gcloud, kubectl, Helm 3.10+, python3, kubeconform, jq, yq, node, openssl, curl and timeout (dig when VERIFY_DNS_RESOLVER is set), network access to the target GKE cluster and the image registry, and operator credentials for the customer GCP project.
metadata:
  chart: agent-relay
  version: "0.3.0"
  standard: "agentskills.io"
---

# Set Up Self-Hosted Agent Relay on GCP

Use the self-contained `agent-relay` umbrella chart to install the portable
single-writer customer shape into an already approved GCP environment. Operate
from either the standalone customer handoff or the chart source repository.
Neither layout provisions GCP infrastructure.

## Safety rules

- Treat every Kubernetes, GCP, DNS, and Helm mutation as external and
  persistent. Show the exact plan and require explicit approval before apply,
  delegation, upgrade, rollback, or teardown.
- Require an exact GCP project ID and immutable project number. Stop if they do
  not match the active `gcloud` project, kube context, or deployment receipt.
- Never print or place tokens, workspace keys, database URLs, signing keys,
  Secret Manager payloads, or generated Kubernetes Secret data in argv, Helm
  values, logs, receipts, temporary renders, or Relay messages.
- Use Workload Identity and existing Kubernetes Secret references. Refuse
  service-account JSON keys and inline Helm secrets.
- Treat the resolved `AGENT_RELAY_BASE_VALUES_FILE` (`values-gcp.yaml`) as a
  structural base only. It contains placeholder domains, resource names,
  repositories, zero image digests, bucket, region, and organization ID; never
  deploy it unchanged for a customer.
- This profile is `portable-single`. Relaycast, RelayAuth, and the stateful
  pipeline components are single-writer; never describe the installation as HA.
- Never use Helm `--atomic` for this suite. Helm can remove or roll back
  Kubernetes resources after a failure, but it cannot reverse a database
  migration or restore SQLite, PostgreSQL, or object data.
- Never promise or initiate automatic rollback. Preserve the failed state,
  determine which migrations ran, and follow the approved database-aware
  recovery plan.
- Relayflows (`components.relayflows`) is an opt-in add-on. The
  durable-actors control plane (`components.durableActors`) and Relayfile
  (`components.relayfile`) are preview components, off by default; enable
  them only when the operator asks for them. Hosted agents/fleet, billing,
  and hosted MCP are outside this installation.

## Required inputs

Obtain these from the operator; do not discover or guess cloud identifiers:

- the extracted handoff root or source-repository root when it cannot be found
  from the working directory or skill location, exported as `HANDOFF_ROOT`;
- `GCP_PROJECT_ID`, immutable `GCP_PROJECT_NUMBER`, `GCP_REGION`, and
  `GKE_CLUSTER`;
- `BASE_DOMAIN` and parent DNS authority;
- release and namespace, normally `agent-relay`;
- names of the global static IP, managed certificate, FrontendConfig, GCS
  bucket, Kubernetes service accounts, and existing Kubernetes Secret;
- Artifact Registry repositories and immutable `sha256:` image digests;
- a customer-specific, non-secret Helm overlay exported as
  `CUSTOMER_VALUES_FILE`;
- backup, retention, and deletion-protection requirements.

The default public origins are:

- Dashboard: `https://$BASE_DOMAIN`
- Control plane: `https://api.$BASE_DOMAIN`
- Relaycast: `https://cast.$BASE_DOMAIN`
- History (Sessions read API and ingest edge): `https://history.$BASE_DOMAIN`

The preview hosts exist only when the customer overlay sets them:
`gkeIngress.hosts.actors` (durable-actors, `https://actors.$BASE_DOMAIN`) and
`gkeIngress.hosts.files` (Relayfile, `https://files.$BASE_DOMAIN`), each with
its component enabled. See `docs/diagrams/agent-relay-architecture.png` in the handoff
for the deployed topology.

## 1. Resolve the layout and run preflight

Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md`.
Use the path supplied by the skill loader; never assume the skill is installed
under `.agents/skills`. If the current directory is not inside the handoff or
repository, set `HANDOFF_ROOT` explicitly.

```bash
: "${SKILL_DIR:?set SKILL_DIR to the directory containing the loaded SKILL.md}"
layout_exports=$(
  bash "$SKILL_DIR/scripts/resolve-layout.sh" "${HANDOFF_ROOT:-}"
)
eval "$layout_exports"
unset layout_exports
printf 'Using %s layout at %s\n' "$AGENT_RELAY_LAYOUT" "$AGENT_RELAY_ROOT"

export CLOUDSDK_CORE_DISABLE_PROMPTS=1
# Pin the exact gcloud-generated context. Every later kubectl and helm command
# passes it explicitly, so switching contexts after preflight cannot redirect
# a mutation to another cluster.
export KUBE_CONTEXT="gke_${GCP_PROJECT_ID}_${GCP_REGION}_${GKE_CLUSTER}"
bash "$SKILL_DIR/scripts/preflight.sh"
```

The resolver supports:

- the extracted customer handoff archive or the source repository, both
  containing `charts/agent-relay/` with `charts/agent-relay/values-gcp.yaml`;
- a standalone directory containing one `agent-relay-*.tgz` and an adjacent
  `values-gcp.yaml`;
- a standalone directory where that package was also extracted to
  `agent-relay/`.

It exports `AGENT_RELAY_CHART_PATH`, `AGENT_RELAY_BASE_VALUES_FILE`, and
optional repository-only check paths. Stop if resolution is ambiguous or
fails; do not guess among multiple chart packages.

The script verifies required variables and tools, active authentication,
project identity, and hostname syntax. For kube-context identity it requires
`KUBE_CONTEXT` and the current context to both equal
`gke_<project>_<region>_<cluster>`, and the context's API server to equal an
endpoint that `gcloud container clusters describe` reports for that cluster. It performs
read-only GCP and Kubernetes configuration checks; it does not validate image
pull access, existing infrastructure, or DNS ownership. Stop on any failure.

Separately confirm that the four requested hostnames are unused or belong to
this installation. Refuse production/shared names without explicit ownership
evidence.

## 2. Verify customer-owned GCP prerequisites

Neither supported layout provides a `sessions-pipeline/stacks/gcp` Alchemy
stack or a `bin/sessions-pipeline` infrastructure command. Do not search for or invoke
those stale paths. Provision or validate prerequisites through the customer's
reviewed infrastructure workflow:

- GKE with Workload Identity;
- PostgreSQL 17 with `vector` and `pg_trgm`, private connectivity, backups,
  deletion protection, and separate runtime/migration-owner roles. History is
  native: the read API and ingest edge use the Sessions Pipeline `hoopdb`
  database through their own logins; no RelayAuth is needed;
- GCS with retention and workload-identity access;
- Artifact Registry access from GKE;
- global static address and authoritative DNS control;
- Secret Manager/Kubernetes Secret delivery that never exposes payloads to
  Helm;
- service accounts and least-privilege IAM bindings.

Review the exact project number, region, cluster, VPC, database, bucket,
repositories, identities, and deletion protection. Require explicit approval
before the customer's infrastructure workflow applies changes.

## 3. Prepare a non-secret customer overlay

Create the overlay outside the skill directory in the operator's approved
configuration location. It may contain Secret names and key names, but never
secret values. Override every proof-specific setting from
`$AGENT_RELAY_BASE_VALUES_FILE`, including:

- `global.tenant.orgId`;
- `gkeIngress.name`, `staticIpName`, `managedCertificateName`,
  `frontendConfigName`, and all four hosts;
- Relaycast, control-plane, History, and Dashboard public origins;
- GCS bucket and region;
- every image repository and immutable digest;
- every `existingSecret` reference;
- workload-identity service-account annotations and customer network-policy
  allowances.

Keep leaf ingresses disabled. Keep public backends as `ClusterIP` Services with
GKE NEGs, and expose them only through the umbrella ingress. Confirm the
existing Secret has all keys documented by
`helm show readme "$AGENT_RELAY_CHART_PATH"` without reading or printing their
values.

Require image versions that agree on login, health, and API paths before
claiming the browser UI works.

## 4. Build, lint, and render

The packaged standalone chart already contains its dependencies. Run dependency
and repository static checks only when the resolver reports those source paths:

```bash
if test -n "$AGENT_RELAY_SESSIONS_PIPELINE_CHART"; then
  helm dependency build "$AGENT_RELAY_SESSIONS_PIPELINE_CHART"
fi
if test "$AGENT_RELAY_LAYOUT" = repository; then
  helm dependency build "$AGENT_RELAY_CHART_PATH"
fi
if test -n "$AGENT_RELAY_STATIC_CHECK"; then
  bash "$AGENT_RELAY_STATIC_CHECK" static
fi

helm show chart "$AGENT_RELAY_CHART_PATH"
helm lint --strict "$AGENT_RELAY_CHART_PATH" \
  -f "$AGENT_RELAY_BASE_VALUES_FILE" \
  -f "$CUSTOMER_VALUES_FILE"
render_file=$(mktemp)
chmod 600 "$render_file"
helm template agent-relay "$AGENT_RELAY_CHART_PATH" \
  --namespace agent-relay --no-hooks \
  -f "$AGENT_RELAY_BASE_VALUES_FILE" \
  -f "$CUSTOMER_VALUES_FILE" >"$render_file"
```

Inspect the render without displaying Secret payloads. Require:

- no Kubernetes Secret manifests or credential values;
- digest-pinned images and no mutable tags;
- no Helm hooks;
- all public Services remain `ClusterIP`;
- TLS configured for all four hosts;
- sensitive Relaycast routes blocked at the edge;
- separate migration-owner and runtime database references;
- service-account token automount disabled unless Kubernetes API access is
  required;
- no remaining vendor proof domain, project, cluster, IP, registry, or resource
  identifiers.

Delete the render after review:

```bash
rm -f "$render_file"
unset render_file
```

## 5. Install or upgrade

Use distinct initial-install and upgrade flows. Do not use
`helm upgrade --install`: an expected initial install must fail if the release
already exists, and an expected upgrade must fail if it does not.

Set non-secret command inputs once:

```bash
export RELEASE="agent-relay"
export NAMESPACE="agent-relay"
export CHART="$AGENT_RELAY_CHART_PATH"
export BASE_VALUES="$AGENT_RELAY_BASE_VALUES_FILE"
```

Never use `--atomic`, `--set`, or `--set-string`. The latter two can expose
secret material through argv and Helm history.

### Initial install

Confirm the namespace and release do not exist, the target images are
compatible with an empty database, and the database and storage targets are
dedicated to this installation. Show `helm diff install` when available;
otherwise show the reviewed render. After explicit approval:

```bash
helm install "$RELEASE" "$CHART" \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" --create-namespace --no-hooks \
  -f "$BASE_VALUES" \
  -f "$CUSTOMER_VALUES_FILE" \
  --wait --wait-for-jobs --timeout 20m
```

If installation fails, stop. Preserve Jobs, events, and data for diagnosis;
do not automatically uninstall, roll back, retry migrations, or delete PVCs.

### Upgrade

Before rendering or mutation:

1. read the release notes and migration compatibility statement for every
   skipped version;
2. capture a complete recovery set while writes are quiesced;
3. prove that recovery set with an isolated restore drill;
4. record whether migrations are backward-compatible or forward-only and use
   a database restore or side-by-side restore as the rollback strategy;
5. require the evidence to match the currently deployed Helm revision.

Create the three non-secret evidence files described in
[`references/pre-upgrade-evidence.md`](references/pre-upgrade-evidence.md), then run the skill-bundled gate:

```bash
bash "$SKILL_DIR/scripts/pre-upgrade-check.sh" \
  --context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" \
  --release "$RELEASE" \
  --target-chart "$CHART" \
  --backup-evidence "$BACKUP_EVIDENCE" \
  --restore-evidence "$RESTORE_EVIDENCE" \
  --compatibility-evidence "$COMPATIBILITY_EVIDENCE"
```

Stop on any failed or stale gate. Show `helm diff upgrade` when available;
otherwise show the reviewed target render and current release history. After
separate approval:

```bash
helm upgrade "$RELEASE" "$CHART" \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" --no-hooks \
  -f "$BASE_VALUES" \
  -f "$CUSTOMER_VALUES_FILE" \
  --wait --wait-for-jobs --timeout 20m
```

Verify migration Jobs and workloads before continuing. An exit code alone is
not deployment proof. If the upgrade fails, stop writes when needed, preserve
the failed state, identify migrations that completed, and execute only the
approved database-aware recovery plan.

`helm rollback` changes release-managed Kubernetes resources. It does not undo
PostgreSQL or SQLite migrations, restore deleted or transformed rows, or
restore object data. Use it only when the compatibility evidence explicitly
proves the previous application can run against the post-migration data, and
only after separate approval; even then the database remains migrated.

Record the Helm revision, chart versions, image digests, namespace, migration
results, recovery ID, and non-secret resource IDs.

### Restore into a target

`--no-hooks` does not stop migrations: the migration and locker init Jobs are
plain Jobs. Never install over restored data without the restore overlay in
[`assets/restore-overlay.yaml`](assets/restore-overlay.yaml), passed last.
Follow [`references/restore-into-target.md`](references/restore-into-target.md)
and confirm the render contains no `Job` objects before installing.

## 6. Publish DNS and verify public endpoints

Prefer a delegated Cloud DNS zone for `BASE_DOMAIN`. Creating a child zone
does not authorize parent-zone changes.

1. Verify the child zone and display only its non-secret NS records.
2. Require explicit approval before publishing parent delegation.
3. Point all four names at the approved global ingress address.
4. Wait for public DNS and the Google-managed certificate.
5. Run the skill-bundled verifier:

```bash
bash "$SKILL_DIR/scripts/verify-public.sh"
```

Read [`references/public-verification.md`](references/public-verification.md)
for explicit origins, health paths, timeouts and what the verifier checks. Do
not continue on a certificate mismatch, redirect, plaintext endpoint,
non-public address, or failed health check.

## 7. Bootstrap and connect Desktop

Create the first workspace through the in-cluster Relaycast admin API. Capture
the one-time workspace key directly into the approved secret store, then
delete any mode-0600 temporary input. Never print or message it.

Set Agent Relay Desktop's trusted deployment origin to the control-plane
origin. The control plane returns scoped Relaycast and History
credentials; do not configure a separate workspace key in Desktop.

Complete device approval, then verify:

- the custom deployment origin;
- the intended workspace UUID and name;
- the registered current session;
- direct delivery enabled;
- session uploader healthy.

## 8. End-to-end proof

Use unique markers and record only non-secret IDs:

1. Register two test agents and list the roster.
2. Send one message and require a reply in the same conversation.
3. Upload a marked real session through Desktop's delivery-batch path.
4. Retry the same batch after dropping the first response and require one
   durable projection.
5. Verify the session appears in Dashboard list, replay, and search.
6. Verify another workspace cannot read it.
7. Restart the read API and ingest edge and repeat the reads.
8. Run an approved idempotent Helm upgrade only after the pre-upgrade gate
   passes.
9. Exercise erasure and prove list, replay, and search no longer return it.
10. Restore a backup into an isolated target and verify it.

Relay acceptance proves outbound send only. Claim bidirectional messaging only
after the reply arrives.

## 9. Handoff

Return:

- all four public URLs;
- project number, region, cluster, namespace, Helm revision, chart versions,
  and image digests;
- verifier output and non-secret proof IDs;
- backup location and restore evidence;
- the `portable-single` limitation;
- the exact upgrade command and database-aware recovery procedure;
- resources owned by this deployment.

Never include credentials, secret payloads, or sensitive response bodies.

## Cleanup

Cleanup is a separately planned and approved operation:

1. Uninstall Helm workloads while preserving retained data by default.
2. Remove only DNS records and IAM bindings named in the deployment receipt.
3. Destroy only customer-approved resources owned by this installation.
4. Never sweep, delete, unlink billing from, or disable APIs on an adopted
   customer project.
