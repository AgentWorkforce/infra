# Agent Relay self-host safety checks

For first-admin recovery and device-code inventory, lookup and approve/deny,
use the [operator login runbook](../../docs/operator-device-login.md). Its
standalone in-pod helper is separate from the read-only safety checks below;
only its explicit approve/deny actions change a device request.

`verify-agent-relay.sh` performs a read-only, non-secret smoke check of an
installed agent-relay Helm suite. It exits nonzero if it cannot prove the
required release, migration, workload, ingress, health, or certificate state.

`pre-upgrade-check.sh` is a separate read-only gate for upgrades. It requires
evidence of a current backup, a successful isolated restore drill, and an
explicit migration-compatibility review that matches the deployed Helm
revision. It also refuses to pass while a selected migration or backup Job is
active or failed.

## Mirroring images to ECR

`mirror-images-to-ecr.sh` copies the images an environment's chart render pins
into that environment's ECR, so it can pull with no GHCR access. It is default
off: without `--apply` it prints the plan and contacts nothing. See its header
for flags, and [the supply chain doc](../../docs/self-hosted-image-supply-chain.md)
for what must be true before an image is used in a customer install.

## Safety properties

Both scripts:

- runs only read operations (`helm status` and `kubectl get`/`api-resources`);
- never requests Kubernetes `Secret` resources;
- never requests pod logs, rendered manifests, Helm values, or response bodies;
- never prints raw command output, ingress certificate references, certificate
  contents, health URLs, or error responses;
- does not run `apply`, `patch`, `delete`, `rollout restart`, Helm upgrade, or
  any other deployment mutation.

It reads cert-manager `Certificate` status when that API is available. A
`Certificate` can reference a Secret in its spec, but the referenced Secret is
not fetched and its name is not printed.

Neither script proves that a database migration is reversible. Helm rollback
changes Kubernetes release resources; it does not reverse database schema or
data changes.

For load-balancer-terminated TLS without Ingress `spec.tls`, repeat
`--external-tls-host <hostname>` for each expected endpoint. Each hostname must
belong to the selected ingress rules (including any `--ingress-host` filter),
and undergoes the normal chain, hostname and expiry checks. This adds a TLS
verification target; it does not skip TLS checks. Supply explicit per-service
`--health-url` paths when their health endpoints differ from `/health`.

## Requirements

- Bash 4 or newer
- `helm`
- `kubectl`
- `python3`
- `curl`
- `openssl`
- GNU `timeout`
- network access to the Kubernetes API and public ingress endpoints
- read access to Deployments, StatefulSets, DaemonSets, Jobs, Pods, Ingresses,
  and, when installed, cert-manager Certificates

## Pre-upgrade gate

Create three non-secret JSON evidence files. The backup must represent the
currently deployed release revision and a recovery set captured while writes
were quiesced:

```json
{
  "recoveryId": "ar-20261102T180000Z",
  "status": "PASS",
  "providerStatus": "SUCCESSFUL",
  "sourceRelease": "agent-relay",
  "sourceRevision": 7,
  "writesQuiesced": true,
  "artifactsComplete": true,
  "completedAt": "2026-11-02T18:10:00Z"
}
```

The restore evidence must identify the same recovery set and a completed
isolated restore:

```json
{
  "recoveryId": "ar-20261102T180000Z",
  "status": "PASS",
  "isolated": true,
  "allVerificationGatesPassed": true,
  "completedAt": "2026-11-02T19:00:00Z"
}
```

The compatibility evidence must name the source revision and reviewed target.
`databaseMigration` is either `backward-compatible` or `forward-only`.
`rollbackStrategy` must be `database-restore` or `side-by-side-restore`;
`helm-rollback` is deliberately not accepted because it cannot undo database
migrations.

```json
{
  "status": "PASS",
  "sourceRevision": 7,
  "targetChartVersion": "0.1.0",
  "databaseMigration": "forward-only",
  "rollbackStrategy": "side-by-side-restore",
  "reviewedAt": "2026-11-02T19:15:00Z"
}
```

Run the gate immediately before the reviewed `helm upgrade`:

```bash
scripts/selfhost/pre-upgrade-check.sh \
  --context my-gcp-context \
  --namespace agent-relay \
  --release agent-relay \
  --target-chart charts/agent-relay \
  --backup-evidence ./evidence/backup.json \
  --restore-evidence ./evidence/restore.json \
  --compatibility-evidence ./evidence/compatibility.json
```

The default maximum ages are 24 hours for backup evidence, 720 hours for a
restore drill, and 168 hours for compatibility review. Tighten them to match
policy. The reviewed `targetChartVersion` must match `helm show chart` for
`--target-chart`. A passing result is a gate, not permission to mutate the
cluster and not a promise that automatic rollback is safe.

## Post-install and post-upgrade verification

### Basic use

```bash
./verify-agent-relay.sh \
  --context my-gcp-context \
  --namespace agent-relay \
  --release agent-relay
```

The default suite selector is:

```text
app.kubernetes.io/instance=<release>
```

Override it when the chart uses another release label:

```bash
./verify-agent-relay.sh \
  --namespace agent-relay \
  --release agent-relay \
  --selector 'app.kubernetes.io/part-of=agent-relay'
```

Run `./verify-agent-relay.sh --help` for all options.

### What is proved

1. **Release:** `helm status --output json` reports `deployed`.
2. **Migrations:** matching Kubernetes Jobs have `Complete=True`, no failed
   attempts, and no incomplete Jobs.
3. **Workloads:** release Deployments, StatefulSets, and DaemonSets have
   observed their current generation and have all desired replicas ready and
   updated.
4. **Pods:** selected Pods are running with every regular container ready, or
   have successfully completed.
5. **Ingress:** matching Ingresses exist, expose rule hosts, and have admitted
   load-balancer addresses.
6. **Health:** every explicit or derived endpoint returns an HTTP 2xx response.
   The response body is discarded.
7. **Certificate:** each selected TLS ingress host completes a trusted TLS
   handshake, matches its hostname, and remains valid for the configured
   minimum period. TLS hosts come from Ingress `spec.tls`, or, for a GKE
   Ingress without `spec.tls`, from the rule hosts of an Ingress that names a
   ManagedCertificate in its `networking.gke.io/managed-certificates`
   annotation. cert-manager `Certificate` readiness is also checked when
   available.
8. **Managed certificate:** every GKE ManagedCertificate named by a selected
   Ingress reports `certificateStatus: Active` and its domains cover the
   hosts it serves.

`--ingress-host HOST` limits derived health URLs, TLS hosts, and certificate
references to that one host, even when it shares an Ingress with other hosts.

Migration Job completion proves only that the selected Job completed. It does
not prove application-version compatibility, downgrade compatibility, or
migration reversibility; those are pre-upgrade review inputs.

By default, health URLs are derived as:

```text
https://<ingress-rule-host>/health
```

For charts with another health route, set `--health-path`:

```bash
./verify-agent-relay.sh \
  --namespace agent-relay \
  --release agent-relay \
  --health-path /healthz
```

The services behind the agent-relay GKE Ingress do not share a health path
(relay-webapp, relay-control, and relayhistory serve `/healthz`;
relaycast serves `/health`), so no single `--health-path` passes for every
host. For the GKE umbrella, supply one URL per host instead:

```bash
./verify-agent-relay.sh \
  --namespace agent-relay \
  --release agent-relay \
  --health-url https://relay.example.com/healthz \
  --health-url https://api.example.com/healthz \
  --health-url https://cast.example.com/health \
  --health-url https://history.example.com/healthz
```

Here `relay.example.com` is `gkeIngress.hosts.root` (served by
relay-webapp), and `api`, `cast`, and `history` are the other
`gkeIngress.hosts` values.

Or supply one or more exact endpoints:

```bash
./verify-agent-relay.sh \
  --namespace agent-relay \
  --release agent-relay \
  --health-url https://relay.example.com/health \
  --health-url https://api.example.com/healthz
```

Health URLs containing user information, passwords, query strings, or fragments
are rejected. URL paths and hosts are not included in proof output. Do not put
tokens or other secrets in a health URL path.

### Migration selection

Without an override, Jobs are first selected by the suite selector, then
identified as migrations when their name or common component labels contain
`migration`, `schema`, `database-setup`, or `db-setup`.

If the chart uses another convention, select its migration Jobs explicitly:

```bash
./verify-agent-relay.sh \
  --namespace agent-relay \
  --release agent-relay \
  --migration-selector 'app.kubernetes.io/component=database-migration'
```

The verifier is evidence-oriented: no discoverable migration Job is a failure.
Use `--allow-missing-migrations` only when successful Jobs are intentionally
deleted and migration proof is provided elsewhere.

### Intentional exceptions

Strict checks can be relaxed for known deployment shapes:

- `--allow-missing-migrations`
- `--allow-missing-workloads`
- `--allow-missing-ingress`
- `--allow-no-tls`

Each accepted exception produces a `PROOF|SKIP|...` record, so omitted evidence
is visible rather than silently treated as success.

### Proof output and exit status

Output is line-oriented and suitable for CI logs:

```text
PROOF|PASS|release|status=deployed
PROOF|PASS|migrations|jobs=1 complete=1
PROOF|PASS|workloads|controllers=4 ready=4
PROOF_RESULT=PASS
PROOF_COUNTS pass=10 fail=0 skip=1
```

The final result is `PASS` only when there are no failed checks. Exit code `0`
means `PASS`, `1` means one or more checks failed, and `2` means invalid usage.

## Syntax checks

Run:

```bash
bash -n pre-upgrade-check.sh
bash -n verify-agent-relay.sh
```

If ShellCheck is installed:

```bash
shellcheck pre-upgrade-check.sh
shellcheck verify-agent-relay.sh
```
