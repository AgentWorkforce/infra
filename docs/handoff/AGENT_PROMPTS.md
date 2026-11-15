# Agent prompts for self-hosted Agent Relay on GCP

Use these prompts with a coding/deployment agent that has access to the
customer's approved GCP project, Kubernetes context, chart bundle, and secret
manager. Attach or install the bundled
`setting-up-self-hosted-agent-relay-gcp` skill first.

Never paste credentials into a prompt.

## Prompt 1: plan and preflight

```text
Use the setting-up-self-hosted-agent-relay-gcp skill.

Plan a new self-hosted Agent Relay installation on GCP. Do not mutate anything
yet. Validate the exact project ID and project number, region, GKE cluster,
namespace, base domain, DNS authority, static IP, Cloud SQL databases and
roles, GCS bucket, Artifact Registry repositories, image digests, Workload
Identity service accounts, and existing Kubernetes Secret names.

The required product scope is Relaycast, Sessions Pipeline (with the native
History read API and ingest edge on the history host), the headless
control-plane API, Relay Dashboard, and Agent Relay Desktop using a custom
deployment origin. RelayAuth is not needed. Relayflows, Relayfile, billing,
provider integrations, and hosted fleet are out of scope.

Require separate runtime and migration credentials for every database. Never print secret values. Return the proposed resource inventory,
customer values overrides, risks, and exact non-mutating validation commands.
Stop before apply and ask for explicit approval.
```

## Prompt 2: install

```text
Use the setting-up-self-hosted-agent-relay-gcp skill and the approved plan.

Install the bundled agent-relay Helm chart into the approved GKE cluster.
First run preflight, dependency, lint, deterministic render, kubeconform, hook,
mutable-image, Secret-object, and proof-placeholder checks. Refuse inline
secrets, service-account JSON keys, private/public hostname mismatches, or
mutable image tags.

Show the final Helm diff or render and ask for explicit approval before the
first mutation. Do not use `--atomic`: database migrations are not reversed by
a Helm rollback. Install with wait and wait-for-jobs, then verify both migration
Jobs, all workloads, GKE backends, DNS, TLS, and health endpoints. Record only
non-secret resource IDs, chart versions, and image digests.
```

## Prompt 3: bootstrap Desktop and prove messaging

```text
Use the setting-up-self-hosted-agent-relay-gcp skill against the installed
release.

Bootstrap the first organization and workspace without printing or messaging
the one-time Relaycast workspace key. Set Agent Relay Desktop's trusted
deployment origin to the public control-plane API origin and complete device
approval.

Register two uniquely named test agents, list the roster, send a marked direct
message, and require a reply in the same conversation. Do not claim
bidirectional messaging until the reply is observed. Return only non-secret
agent names and message IDs.
```

## Prompt 4: prove Sessions end to end

```text
Use the setting-up-self-hosted-agent-relay-gcp skill.

Upload a uniquely marked real Desktop session through
/v1/delivery/batches. Retry the identical batch and require the same durable
receipt with one projection. Verify Dashboard list, search, and replay,
cross-workspace denial, persistence after a read API and ingest edge restart, and public
TLS health.

Before any Helm upgrade, run the pre-upgrade recovery gate from
docs/selfhost-backup-restore.md: review migration compatibility to the exact
target versions, capture a complete recovery set from the currently deployed
revision while writes are quiesced, restore it into an isolated target and pass
every verification gate, then run the read-only
scripts/selfhost/pre-upgrade-check.sh with the backup, restore, and
compatibility evidence. Stop and ask for explicit approval with that evidence.
Do not run helm upgrade until approval is given; a passing gate does not
authorize the upgrade or make a migration reversible.

After approval, run the Helm upgrade without --atomic, verify the migration
Jobs and all workloads, and repeat the session checks above. Return non-secret
IDs and any remaining blockers.
```

## Prompt 5: audit or recover an installation

```text
Use the setting-up-self-hosted-agent-relay-gcp skill in audit/recovery mode.

Do not change the cluster initially. Compare the approved deployment receipt,
Helm values, live Kubernetes resources, image digests, DNS, certificate,
database separation, Workload Identity, network policies, migrations,
backups, and Desktop deployment origin. Never display Secret data.

Explain each drift or failure with evidence. Propose the smallest reversible
repair and require explicit approval before mutation. Never delete retained
data, DNS, IAM, databases, buckets, or adopted customer resources without
separate teardown approval.
```
