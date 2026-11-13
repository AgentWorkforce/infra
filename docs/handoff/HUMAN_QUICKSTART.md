# Human quick start: self-hosted Agent Relay on GCP

This handoff installs Relaycast, Sessions Pipeline (including the native
History read API and ingest edge), the headless control-plane API, and Relay
Dashboard. RelayAuth is not needed. It intentionally excludes
Flows, Relayfile, billing, hosted fleet, and provider integrations.

The deployment is `portable-single`, not highly available.

## 1. Prerequisites

- GKE 1.28+
- PostgreSQL 17 with `vector` and `pg_trgm`
- separate runtime and migration-owner database roles
- GKE Workload Identity and a GCS bucket for Sessions objects; the Sessions Pipeline
  worker and AlleyOop service accounts need object access to it (native GCS,
  `locker.provider: gcs`; no storage key)
- Artifact Registry, a global static address, and authoritative DNS
- `gcloud`, `kubectl`, `helm`, `kubeconform`, `jq`, `yq`, Node, and OpenSSL
- approved immutable images in a registry the customer GKE nodes can pull

The internal proof API and Dashboard images are not a public
customer distribution channel. Promote approved builds into the customer registry and
replace every repository and digest in the values overlay.

## 2. Verify, unpack, and build chart dependencies

The handoff is `agent-relay-customer-handoff-<rev12>.tar.gz` (or the identical
`.zip`) plus `SHA256SUMS`; see [`HANDOFF.md`](HANDOFF.md) for the layout.

```bash
sha256sum -c SHA256SUMS            # macOS: shasum -a 256 -c SHA256SUMS
tar -xzf agent-relay-customer-handoff-<rev12>.tar.gz
cd agent-relay-customer-handoff
sha256sum -c SHA256SUMS

# The charts ship as source. Build the nested Sessions Pipeline chart first: Helm does
# not vendor the dependencies of a file:// dependency recursively.
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add minio https://charts.min.io/
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm dependency build charts/sessions-pipeline
helm dependency build charts/agent-relay

cp charts/agent-relay/values-gcp.yaml customer-values.yaml
```

Install the skill by copying
`.agents/skills/setting-up-self-hosted-agent-relay-gcp/` into the agent’s
skills directory, or give its `SKILL.md` to the deployment agent as the
operating procedure.

## 3. Customize

Edit `customer-values.yaml` and replace every example:

- project, region, bucket, registry, and organization ID;
- Dashboard, API, Relaycast, and History hostname;
- static IP, ManagedCertificate, and FrontendConfig name;
- Kubernetes Secret and service-account reference;
- image repository and immutable `sha256:` digest;
- PostgreSQL runtime role.

Keep credentials out of the values file. Create the documented Kubernetes
Secret from an approved secret manager or private mode-0600 files. The control
API and the Sessions Pipeline each need separate runtime and migration
database URLs.

## 4. Validate

```bash
helm lint --strict charts/agent-relay -f customer-values.yaml
helm template agent-relay charts/agent-relay \
  --namespace agent-relay --no-hooks \
  -f customer-values.yaml |
  kubeconform -strict -summary -ignore-missing-schemas
```

Confirm the render contains no Secret objects, mutable image tags, public
LoadBalancer Services, Helm hooks, or example names.

## 5. Install

```bash
helm install agent-relay charts/agent-relay \
  --namespace agent-relay --create-namespace --no-hooks \
  -f customer-values.yaml \
  --wait --wait-for-jobs --timeout 20m
```

Do not add `--atomic`: Helm rollback does not reverse completed database
migrations. Upgrades require the pre-upgrade recovery gate in
`docs/selfhost-backup-restore.md` (a quiesced recovery set, a tested isolated
restore, and `scripts/selfhost/pre-upgrade-check.sh`) and explicit approval
before `helm upgrade`.

Wait for the migration Jobs, all Deployments, GKE backends, public DNS, and
the managed certificate.

## 6. Connect Desktop

In Agent Relay Desktop Settings, set the trusted deployment origin to the
public API origin, for example `https://api.relay.customer.example`. The
current implementation accepts only a bare public HTTPS DNS origin. Complete
device approval; the control plane supplies scoped Relaycast and History
credentials.

## 7. Verify

Run the bundled skill’s `scripts/verify-public.sh`, then:

1. register two agents and require a ping plus reply;
2. upload a marked session through `/v1/delivery/batches`;
3. retry the identical batch and require the same durable receipt;
4. verify Dashboard list, search, and replay;
5. verify cross-workspace denial and restart persistence;
6. capture a quiesced recovery set and test restore into an isolated target;
   only then, with the pre-upgrade gate passing and explicit approval, run an
   idempotent Helm upgrade.

Do not claim customer readiness until all checks pass with the customer’s
domains, registry, identities, and backup policy.
