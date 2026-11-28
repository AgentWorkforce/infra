# Agent Relay on Azure (AKS): install guide

A working install of the `agent-relay` chart on Azure Kubernetes Service, the
Azure counterpart of the EKS and GKE guides. It follows the EKS guide's steps
and site values and changes only what Azure forces.

**Status: community-contributed, proven once.** One fresh install on
2026-11-14 (AKS 1.36, East US 2) of release **agent-relay-2026.11.0** (chart
0.6.46) with the `searchIndexer.locker.credentials` option from this change
applied to that chart. The four edge checks passed, a headless sign-in by
operator device approval worked, two agents exchanged messages through
Relaycast, and an uploaded session was indexed. See
[What was not proven](#what-was-not-proven) before a production rollout.
The message receipts image patch, and a backup and restore of Control's
database and Relaycast's SQLite volume around it, were qualified separately on
agent-relay-2026.11.8: see
[AKS receipts upgrade qualification](#aks-receipts-upgrade-qualification).

This guide installs release **agent-relay-2026.11.19** (chart agent-relay 0.7.81,
sessions-pipeline 0.8.58). `searchIndexer.locker.credentials` first shipped
in agent-relay-2026.11.2. Earlier releases do not render the
indexer's MinIO keys, so its uploads are never indexed.

| File | What it is |
|---|---|
| `values.yaml` | Site values, applied after the chart package's `values-eks.yaml` and before the release's `release-images.values.yaml` |
| `postgres-tls.yaml` | cert-manager Issuers and Certificates: a 10-year CA and the server certificate for the in-cluster Postgres |
| `postgres-values.yaml` | Overrides for `deps/cnpg-cluster-values.yaml` (the pinned HoopDb Postgres) |
| `postgres-setup.sh` | Databases, roles and credential files: the `selfhosted` counterpart of `rds-setup.sh` and `cloud-sql-setup.sh` |
| `ingress.yaml` | The edge: one Traefik Ingress, the host and path rules of `scripts/selfhost/eks-alb-ingress.sh`. Generated from the chart's `traefikIngress` template by `scripts/selfhost/aks-traefik-ingress.sh`; do not hand-edit. With agent-relay chart 0.7.77 or later, set `traefikIngress.enabled` in `values.yaml` instead |
| `relaygate-values.yaml` | Built-in relaygate in sessions-only mode (agent-relay chart 0.7.77 or later): the history host goes through relaygate, Relaycast stays direct ([step 8b](#8b-built-in-relaygate-sessions-only-chart-0777-or-later)) |

## How Azure differs

For an existing corporate VPN, an optional
[connector network profile](../vpn-networking.md) supplies a dedicated subnet,
static outbound NAT and firewall rules in an existing VNet. It creates no VPN
software or AKS resources and does not extend this guide's qualification.

| AWS (EKS guide) | Azure (this guide) | Why |
|---|---|---|
| RDS + `rds-setup.sh` (`databaseMode: rds`) | In-cluster CloudNativePG, the pinned `deps/cnpg-cluster-values.yaml`, + `postgres-setup.sh` (`databaseMode: selfhosted`) | The services image has `rds`, `cloudsql` and `selfhosted` database modes. Azure Database for PostgreSQL fits none: its admin role is neither `rds_superuser` nor `cloudsqlsuperuser`, and it is not a superuser. |
| S3 through EKS Pod Identity | The chart's bundled MinIO (`session-object-storage`) on an Azure disk, static keys from a Secret | The ingest charts (`alleyoop`, `ingestEdge`, `searchIndexer`) take S3 or GCS only. The worker chart also takes native Azure Blob (`locker.provider: azure`, [step 13b](#13b-session-analysis-on-native-azure-blob-preview)), but the whole pipeline cannot run on Blob until the ingest charts do. |
| OpenSearch (SigV4) | PostgreSQL search (`search.backend: postgres`), as on GKE | The OpenSearch writer signs with AWS credentials. |
| ALB + ACM | Traefik + cert-manager (Let's Encrypt HTTP-01) | Same hosts, paths and edge denials. |
| Route 53 or your DNS | Optional: an Azure public IP DNS label per host (`<label>.<region>.cloudapp.azure.com`) | No DNS zone is needed. |

One chart change makes this possible: the search indexer could not take static
S3 keys, so it could not read a MinIO Locker. `searchIndexer.locker.credentials.mode: secret`
(with `existingSecret`, `accessKeyIdKey`, `secretAccessKeyKey`) renders
`LOCKER_ACCESS_KEY_ID` and `LOCKER_SECRET_ACCESS_KEY`, as `ingestEdge` and
`nativeConsumer` already can. It is unset by default and existing renders do
not change.

## Steps

Tools: `az`, `kubectl`, `helm` 3.10+, `jq`, `yq`, `openssl`.

The chart and its image pins come from the release's assets; nothing is built
from a checkout. The repository supplies only this directory's files and the
pinned `deps/` values. Every later command runs in `docs/azure-install`:

```sh
git clone https://github.com/AgentWorkforce/infra.git && cd infra/docs/azure-install
mkdir release && gh release download agent-relay-2026.11.19 -R AgentWorkforce/infra -D release
(cd release && shasum -a 256 -c SHA256SUMS && tar -xzf agent-relay-0.7.81.tgz) | tail -1
# Public GHCR images: no mirror root.
sed 's#__IMAGE_MIRROR_ROOT__/##' release/release-images.values.yaml > release-images.values.yaml
CHART=release/agent-relay-0.7.81.tgz
```

**Done when:** every checksum line ends in `OK` (the last is
`release-notes.md: OK`). Use another mirror root in that `sed` if you mirror
the images.

### 1. Cluster

```sh
az group create -n <resource group> -l <region>
az aks create -g <resource group> -n <cluster> --node-count 2 --node-vm-size <4 vCPU / 16 GB size> \
  --node-osdisk-size 128 --enable-cluster-autoscaler --min-count 2 --max-count 4 \
  --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
  --enable-oidc-issuer --enable-workload-identity --enable-managed-identity --no-ssh-key
az aks get-credentials -g <resource group> -n <cluster>
```

**Done when:** `kubectl get nodes` shows two `Ready` nodes and one StorageClass
is marked `(default)`.

### 2. Operators and the edge

```sh
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add jetstack https://charts.jetstack.io
helm repo add traefik https://traefik.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 -n cnpg-system --create-namespace \
  -f ../../deps/cnpg-operator-values.yaml --wait
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true --wait
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  --set "service.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name=<root label>" \
  --set service.spec.externalTrafficPolicy=Local --set ingressClass.enabled=true --wait
```

The CloudNativePG version is this repository's pin (`deps/pins.txt`).

For Azure DNS labels, add one more `LoadBalancer` Service per remaining host
(api, cast, history), each selecting the Traefik pods and carrying its own
`service.beta.kubernetes.io/azure-dns-label-name` annotation. With your own
DNS zone, point four names at Traefik's one address instead.

Create a `ClusterIssuer` named `letsencrypt` with an HTTP-01 solver on the
`traefik` ingress class.

**Done when:** all four host names resolve to a Traefik address.

### 3. Postgres

```sh
kubectl create namespace agent-relay
kubectl apply -f postgres-tls.yaml
kubectl -n agent-relay wait --for=condition=Ready certificate/postgres-ca certificate/hoopdb-server
helm upgrade --install hoopdb cnpg/cluster --version 0.9.0 -n agent-relay \
  -f ../../deps/cnpg-cluster-values.yaml -f postgres-values.yaml
```

The server certificate is issued under a 10-year CA because the read API,
ingest edge and search indexer pin the CA's SHA-256. CloudNativePG's own CA
lasts 90 days and rotates.

**Done when:** `kubectl -n agent-relay get cluster hoopdb` reports
`Cluster in healthy state`.

### 4. Databases and roles

```sh
export SERVICES_IMAGE="$(yq '."sessions-pipeline".worker.image | .repository + "@" + .digest' release-images.values.yaml)"
bash postgres-setup.sh pre
```

It creates the `relaycontrol` database and its roles, the HoopDb bootstrap
roles, the `postgres-ca` ConfigMap and every credential file under
`~/.agent-relay-install` (mode 0700). It prints no password. SQL runs as the
CloudNativePG superuser by `kubectl exec` into the primary, as the chart's own
privileged Jobs do.

On a fresh install, `hoopdb_owner` owns HoopDb and both migration/bootstrap
Secret keys contain only that non-superuser URL. The PostgreSQL superuser is
used only by this setup command and is never written into the cluster. A
rerun detects an older `hoop`-owned install and leaves its objects and role
graph unchanged; see the temporary-Secret upgrade flow below.

**Done when:** it ends with `pre done`.

### 5. Values and Secrets

Replace the placeholders in `values.yaml`: `__ORG_ID__`, `__ORG_NAME__`,
`__ADMIN_EMAIL__`, `__HOST_ROOT__`, `__HOST_API__`, `__HOST_CAST__`,
`__HOST_HISTORY__`, `__SESSIONS_BUCKET__`, and `__POSTGRES_CA_SHA256__` (from
`~/.agent-relay-install/postgres-ca.sha256`). `__LLM_MODEL__` stays, as in the
EKS guide.

Create the Secrets as in
[step 10 of the GKE guide](../gcp-install/0-START-HERE.md#10-create-the-secrets),
without the Relaycast
database keys (Relaycast runs on SQLite here) and with one more Secret for
MinIO:

```sh
S=~/.agent-relay-install/secret-files
( umask 077; mkdir -p "$S/sessions-pipeline-locker"
for k in selfhost-bootstrap-token selfhost-setup-key relaycast-internal-secret \
         relaycast-workspace-bootstrap-secret relaycontrol-introspect-secret session-read-api-secret \
         selfhost-encryption-key; do
  [ -s "$S/agent-relay-secrets/$k" ] || openssl rand -hex 32 | tr -d '\n' > "$S/agent-relay-secrets/$k"
done
[ -s "$S/agent-relay-secrets/SUMMARY_MASTER_KEYS" ] || printf 'k1:%s' "$(openssl rand -hex 32)" > "$S/agent-relay-secrets/SUMMARY_MASTER_KEYS"
cp "$S/agent-relay-secrets/relaycontrol-introspect-secret" "$S/agent-relay-ingest-edge-runtime/introspect-secret"
[ -s "$S/sessions-pipeline-locker/rootUser" ] || printf 'agentrelay' > "$S/sessions-pipeline-locker/rootUser"
[ -s "$S/sessions-pipeline-locker/rootPassword" ] || openssl rand -hex 24 | tr -d '\n' > "$S/sessions-pipeline-locker/rootPassword" )
put_secret() { # create the Secret, or replace it in place; never kubectl apply, which copies
               # every value into a last-applied annotation (replace also drops an old one)
  if kubectl -n agent-relay get secret "$1" >/dev/null 2>&1; then
    kubectl -n agent-relay create secret generic "$@" --dry-run=client -o yaml | kubectl replace -f -
  else
    kubectl -n agent-relay create secret generic "$@"
  fi
}
for name in agent-relay-secrets agent-relay-read-api agent-relay-ingest-edge-runtime \
            search-indexer-runtime search-indexer-owner sessions-pipeline-locker; do
  put_secret "$name" --from-file="$S/$name"
done
```

### 6. Install

```sh
helm upgrade --install agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
for j in $(kubectl -n agent-relay get jobs -o name | grep -E 'relay-control-migrate|agent-relay-worker-migrate'); do
  kubectl -n agent-relay wait --for=condition=complete "$j" --timeout=20m
done
```

**Expected:** the read API, ingest edge, search indexer and the
`search-indexer-bootstrap` Job fail until step 7, as on EKS.

### 7. Switch on the service logins

```sh
bash postgres-setup.sh post
kubectl -n agent-relay rollout restart deploy/agent-relay-read-api deploy/agent-relay-ingest-edge deploy/agent-relay-search-indexer
for j in $(kubectl -n agent-relay get jobs -o name | grep search-indexer-bootstrap); do kubectl -n agent-relay delete "$j"; done
helm upgrade --install agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay wait --for=condition=complete "$(kubectl -n agent-relay get jobs -o name | grep search-indexer-bootstrap)" --timeout=10m
kubectl -n agent-relay rollout status deploy --timeout=10m
bash postgres-setup.sh finalize
```

**Done when:** three `login ok ... tls=true` lines, the bootstrap Job
completes, every pod is `Running`, and `finalize` prints `owner createrole: false`.

Before any later upgrade, rerun `postgres-setup.sh pre` to identify the saved
layout, then follow the upgrade flow below.

### 8. Edge and checks

Replace the four `__HOST_*__` placeholders in `ingress.yaml`, then:

```sh
kubectl apply -f ingress.yaml
kubectl -n agent-relay wait --for=condition=Ready certificate/agent-relay-tls --timeout=10m
curl -fsS "https://<api host>/readyz" && echo " api ok"
curl -fsS "https://<cast host>/health" && echo " cast ok"
curl -fsS -o /dev/null -w "dashboard %{http_code}\n" "https://<root host>/"
curl -s -o /dev/null -w "history %{http_code}\n" "https://<history host>/v1/sessions"
```

#### Upgrading an edge applied from an older `ingress.yaml`

A chart upgrade does not change an Ingress that was applied by hand. An
`ingress.yaml` from a guide older than chart 0.7.68 has no rule for
`/v1/relayfacts` or `/v1/coordination` on the history host, so Traefik answers
both with 503 from `edge-deny` and relay-control's relayfacts and coordination
tools report "temporarily unavailable", whatever chart version runs. Count the
two rules:

```sh
kubectl -n agent-relay get ingress agent-relay \
  -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path}{"\n"}{end}' \
  | grep -c -x -E '/v1/(relayfacts|coordination)'
```

`2` means both are routed; `0` means the Ingress predates them. After the
chart upgrade, either apply this release's `ingress.yaml` again (placeholders
replaced, as above) or move the edge into the release as below. The answer
then comes from the read API instead of the edge: `501 relayfacts_disabled`
for a signed-in reader until the feature is turned on.

With the gate on (8b), charts 0.7.77 to 0.7.81 deny both paths at the edge
unless `global.relaygate.gateOnly.relayfactsRoutes: true` is set; from 0.7.82
they are routed to relaygate by default.

#### Moving the edge into the release (chart 0.7.77 or later)

With a chart that has `traefikIngress`, the release renders the same edge.
An install that applied `ingress.yaml` owns an Ingress `agent-relay` and a
Service `edge-deny` that Helm did not create, so hand both to the release,
then set `traefikIngress.enabled: true` in `values.yaml` and upgrade. With the
gate off the release renders the same objects, so nothing changes on the wire:

```sh
for o in ingress/agent-relay service/edge-deny; do
  kubectl -n agent-relay label "$o" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl -n agent-relay annotate "$o" meta.helm.sh/release-name=agent-relay meta.helm.sh/release-namespace=agent-relay --overwrite
done
```

### 8b. Built-in relaygate, sessions-only (chart 0.7.77 or later)

The recommended setup puts relaygate in front of History: the history host
goes through relaygate, the cast host stays on Relaycast
([relaygate](../self-hosted-relaygate.md#built-in-sessions-only)). It needs
agent-relay chart **0.7.77 or later** and the release-rendered edge above
(`traefikIngress.enabled: true`); skip this step on older charts. The guide's
Cilium dataplane enforces the NetworkPolicy it relies on.

1. In `relaygate-values.yaml`, replace `__HOST_HISTORY__` and `__HOST_ROOT__`,
   and fill `policy.controlPrincipals` (your org
   id, the admins' emails; `readerKinds` only with relay-control 0.5.38 or
   later and `relay-control.services.sessionReadMintIncludeReaderKind: true`). helm refuses to render until they
   are set.
2. Create the admin Secret (used once, for the adopt in 4):

   ```sh
   kubectl -n agent-relay get secret relaygate-admin >/dev/null 2>&1 || \
     openssl rand -hex 32 | tr -d '\n' | kubectl -n agent-relay create secret generic relaygate-admin --from-file=token=/dev/stdin
   ```

3. Add `-f relaygate-values.yaml` right after `-f values.yaml` in **every**
   `helm upgrade` of this install from now on, including the ones in the later
   steps and in the upgrade flow below. **An upgrade without it turns the gate
   off** and restores direct History routes and direct access to the reader
   and ingest edge.
4. Check the edge, then adopt the sessions that existed before the gate, dry
   run first ([existing sessions](../self-hosted-relaygate.md#existing-sessions-adopt-them-once)):

   ```sh
   curl -s -o /dev/null -w "history /admin %{http_code} (503 expected)\n" "https://<history host>/admin/v1/audit"
   ```

**Done when:** `api ok`, `cast ok`, `dashboard 200` and `history 401`.

Edge denials go to a Service with no endpoints, as on GKE, so they answer 503
(the ALB edge answers 404).

### 9. First sign-in

Continue with
[step 15 of the GKE guide](../gcp-install/0-START-HERE.md#15-first-sign-in-then-add-users)
(setup-key sign-in, then users).

### 10. Output and the daily digest

`values.yaml` turns on the Output and daily-digest reads and the indexer's
output facts writer, but a workspace answers them only after the output facts
bootstrap Job has marked it (until then: 501 `output_backfill_incomplete` /
`digest_backfill_incomplete`). The Job marks only workspaces that already have
sessions, so run it after the first sessions of a workspace arrive. Merge this
into the existing `sessions-pipeline.searchIndexer` block of `values.yaml`:

```yaml
sessions-pipeline:
  searchIndexer:
    outputFacts:
      bootstrap:
        enabled: true
        runId: "1"
```

```sh
helm upgrade agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay wait --for=condition=complete --timeout=2h \
  job -l app.kubernetes.io/component=output-facts-bootstrap
```

When another workspace starts uploading, change `runId` and run it again. Exit
codes and verification are in the
[sessions-pipeline chart README](../../charts/sessions-pipeline/README.md).

**Done when:** the Job completes and the workspace's Output page loads.

### 11. Titles and summaries (optional, after first sign-in)

Summaries are extractive by default (`BOB_COSTAS_MODEL: "off"`: no model, no
data leaves the cluster). Model-written titles, briefs and summaries need an
OpenAI Responses API key (or an OpenAI-compatible gateway) and a model, e.g.
`gpt-5.6-luna`. Follow
[step 16 of the GKE guide](../gcp-install/0-START-HERE.md#16-turn-on-titles-and-summaries-optional-after-first-sign-in)
with `NAMESPACE=agent-relay`:

- **16a** creates the `agent-relay-llm` Secret from stdin (never on a command
  line, never `kubectl apply`);
- **16b** lists workspace IDs: `bash ../gcp-install/workspace-ids.sh <domain> agent-relay <api hostname>`
  (with Azure DNS labels the API hostname is your `__HOST_API__` value, not
  `api.<domain>`);
- **16c** edits `values.yaml` with one `yq` command (it reads `SERVICES_IMAGE`
  from step 4 above).

Then apply it with this guide's files:

```sh
helm upgrade agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay rollout status deploy/agent-relay-worker-session-brief deploy/agent-relay-worker-session-summary-worker --timeout=10m
```

**Done when:** both rollouts finish and a new session shows a title and a
summary in the dashboard. The GKE step lists the log lines that show model
versus extractive summaries, the daily limits, and how to turn it off.

### 12. Large sessions: search index limits (optional)

By default the search indexer indexes a session whole only up to 64 MiB and
100,000 events. A larger session is recorded as partial. A workspace search that
would include it then answers 501 `session_partial`, unless the read API is set
to skip partial sessions. These settings need **agent-relay-2026.11.11 or
later** (chart 0.7.25+). This guide installs 2026.11.19, which supports them.
If you run an older release, upgrade first.

All are unset by default. When it renders, the chart checks only the format of
`maxScopeBytes` (bytes, or a MiB/GiB size), not its numeric range, so keep it
within 64MiB..256MiB yourself. It does refuse out-of-range `maxScopeEvents` and
`maxRows`. Merge into `values.yaml`:

```yaml
sessions-pipeline:
  searchIndexer:
    limits:
      maxScopeBytes: 256MiB    # SEARCH_INDEX_MAX_SCOPE_BYTES: 64MiB..256MiB
      maxScopeEvents: 1000000  # SEARCH_INDEX_MAX_SCOPE_EVENTS: 100000..1000000
      maxRows: 1000000         # SEARCH_INDEX_MAX_ROWS: 500000..1000000
    resources:
      limits:
        memory: 3Gi            # raise with the limits; the indexer holds a scope in memory several times over
  sessionReadApi:
    search:
      partialSessions: skip    # READ_API_SEARCH_PARTIAL_SESSIONS: refuse (image default) or skip
```

- **The limits** apply to the search indexer only (Deployment
  `agent-relay-search-indexer`, service `session-pipeline-consumer`). It
  re-sends partial sessions on every reconcile tick, so sessions that were
  partial are indexed whole after the upgrade without a manual re-index.
- **`partialSessions: skip`** makes a search that would include a still-partial
  session answer 200, marked incomplete with the `X-Sessions-Read-Incomplete`
  header, and leaves that session's rows out.
- Set only what you need: raise `maxScopeBytes` for sessions with large tool
  outputs, `maxScopeEvents` for very long sessions.
- **Changing `searchIndexer.resources` renames the `search-indexer-bootstrap`
  Job**, so Helm runs it once more. The limits and `partialSessions` alone do
  not. On an install whose `~/.agent-relay-install/hoopdb-layout` is
  `legacy-admin`, that Job reads the temporary `hoopdb-admin-jobs` Secret,
  which no longer exists: do not run the command below. Keep `$CHART` and
  `release-images.values.yaml` as they are, set `NEW_DIR=release`, and run the
  script in [Upgrades](#upgrades-dedicated-owner-and-legacy-temporary-credentials)
  from `release_jobs()` on. It creates the Secret, upgrades with the new
  values, waits for the Job and deletes the Secret.

```sh
helm upgrade agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay wait --for=condition=complete "$(kubectl -n agent-relay get jobs -o name | grep search-indexer-bootstrap)" --timeout=10m
kubectl -n agent-relay rollout status deploy/agent-relay-search-indexer deploy/agent-relay-read-api --timeout=10m
```

**Done when:** the bootstrap Job is complete, both rollouts finish, and a
workspace search that answered 501 `session_partial` answers 200.

### 13. Session analysis (optional)

The session-analysis worker (`SERVICE=session-analysis`) can run against the
bundled MinIO with static keys. It is off by default. Before you start:

- **Image.** Static keys and the MinIO endpoint need a services image with the
  runner's S3-compatible store support (relayhistory-pipeline 9b29a3dd or
  later). The services image agent-relay-2026.11.19 pins is built from
  relayhistory-pipeline `abd4e8a8`, which is after it, so with this release the
  worker uses the shared image and needs no `sessionAnalysis.image`. An older
  release's image predates it: the pod exits 2 at startup with
  `credentials_mode_invalid`, so there pin a newer, reviewed repository plus
  digest under `sessionAnalysis.image`. That changes only the session-analysis
  Deployment; do not replace the shared worker image merely to start this
  optional worker. The worker has not been run on AKS from this release.
- **Versioning.** The runner checks at startup that the bucket is versioned
  and refuses to start otherwise (`bucket_not_versioned`). The worker's
  `locker-init` Job (`lockerInit.enabled: true` in `values.yaml`) runs the
  services' `SERVICE=locker-init`. It creates the Locker bucket if needed and
  enables versioning on it, also on an existing unversioned bucket. So
  `sessionAnalysis.bucket` must be that same bucket (`__SESSIONS_BUCKET__`).
- **Model key.** It needs the `agent-relay-llm` Secret from step 11.
- **Database login.** It uses the HoopDb runtime role, from a Secret of its
  own. The runner refuses `ssl*` query parameters in the URL (TLS comes from
  `postgresTls`), so the URL is the runtime role's `HOOPDB_URL` without
  `?sslmode=verify-full`:

```sh
S=~/.agent-relay-install/secret-files
( umask 077; mkdir -p "$S/session-analysis-db"
sed 's/?sslmode=verify-full$//' "$S/agent-relay-secrets/HOOPDB_URL" > "$S/session-analysis-db/url" )
put_secret session-analysis-db --from-file="$S/session-analysis-db"   # put_secret from step 5
```

Uncomment the `sessionAnalysis` block under `sessions-pipeline.worker` in
`values.yaml`. It reads the MinIO keys from the existing
`sessions-pipeline-locker` Secret by name, and the chart never takes key
values. Keep `run: false` for the first upgrade.

Because the dedicated image is scoped to this Deployment, it does not rename
or rerun the worker `migrate` and `locker-init` Jobs and does not roll the
summary, status or index workers. Upgrade dormant and wait for the new pod:

```sh
helm upgrade agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay rollout status deploy/agent-relay-worker-session-analysis --timeout=10m
```

Then set `run: true` and upgrade again. If the pod exits with code 2, its log
line names the refused setting (for example `endpoint_invalid` or
`bucket_not_versioned`). Exit code 1 (for example
`bucket_versioning_unavailable`) means MinIO was not reachable yet, and the
pod retries.

This guide does not turn on the worker NetworkPolicy. If you turn it on, list
the MinIO pods in `worker.networkPolicy.objectStorage.to` with port 9000, and
the model API in `sessionAnalysis.modelEgress`. With static keys no workload
identity rule is needed.

**Done when:** the rollout finishes with `run: true` and the pod stays Ready.

### 13b. Session analysis on native Azure Blob (preview)

The worker chart (`sessions-pipeline-worker`) also takes native Azure Blob
Storage: `locker.provider: azure`. The workers and the session-analysis
runner then read and write the container directly with the storage account's
Shared Key, with no S3 settings and no MinIO. Use this only when every Locker
writer is on the same container. On this release the ingest charts
(`alleyoop`, `ingestEdge`, `searchIndexer`) still take S3 or GCS only, so a
default install keeps MinIO and runs session analysis as in step 13. This step
documents the worker values so the chart renders and they are ready when the
ingest side moves to Blob.

Before you start:

- **Image.** The Azure Locker and the Azure runner need sessions-pipeline
  `10d27ff4` or later in every worker, not only in session analysis:
  `locker.provider: azure` switches the summary, status and index workers and
  the `migrate` Job too, and they all run the shared worker image.
  agent-relay-2026.11.24 pins a services image built from `fefbc87c`, which
  has them. On an older release, pinning `sessionAnalysis.image` alone is not
  enough: the other workers keep an image without the Azure Locker. Use
  agent-relay-2026.11.24 or later, or pin the shared worker image
  (`worker.image`) to a reviewed digest of such a build.
- **Storage account.** Turn on blob versioning on the account, and create the
  container outside the chart (`lockerInit.enabled: false`). Before it claims
  any job, the runner proves versioning at startup by writing a probe blob,
  erasing it and checking that it is gone. A
  missing container refuses as `blob_container_missing`, versioning off as
  `blob_not_versioned`, a wrong key as `blob_auth_refused`. The sweeper's strict
  erase also needs permanent delete if soft delete is on.
- **Key.** Put the account key in the shared worker Secret (`existingSecret`)
  under `LOCKER_AZURE_ACCOUNT_KEY`. If you only have a connection string, the
  key is its `AccountKey=` part. The chart takes the Secret name only. The
  workers read the key as `LOCKER_AZURE_ACCOUNT_KEY`, and the runner reads it as a
  read-only file. To give the runner its own Secret instead, set
  `sessionAnalysis.azure.accountKeySecret`. Entra workload identity and SAS are
  not supported yet.

Values under `sessions-pipeline.worker` (placeholders):

```yaml
existingSecret: sessions-pipeline
locker:
  provider: azure
  bucket: __SESSIONS_CONTAINER__        # the container (3-63 lowercase letters, digits, single hyphens)
  azure:
    account: __STORAGE_ACCOUNT__         # 3-24 lowercase letters or digits
  endpoint: ""                           # required: clears the guide's MinIO endpoint; empty is https://<account>.blob.core.windows.net
  credentials: { mode: secret }
lockerInit:
  enabled: false
sessionAnalysis:
  enabled: true
  run: false
  keyPrefix: 96bulls
  # bucket, bucketRegion, s3Credentials, s3KeysSecret, s3Endpoint,
  # allowInClusterHttp and s3VersioningCheck stay unset on Azure (the runner
  # refuses S3 settings there); decisionRecords cannot be "true".
  modelKeySecret: { name: agent-relay-llm, key: OPENAI_API_KEY }
  databaseSecret: { name: session-analysis-db, key: url }
  postgresTls: { profile: custom-ca, caConfigMap: postgres-ca, caKey: ca.crt, sha256: __POSTGRES_CA_SHA256__ }
```

Roll it out as in step 13: dormant first, then `run: true`. With the worker
NetworkPolicy on, `objectStorage.to` must reach the account's blob endpoint
on 443. No workload identity rule is needed. The chart rejects these values
at render time instead of letting the pod crash-loop, and
`ci/sessions-pipeline-worker-advisor-analysis/test_chart.py` covers that.
Nothing here has run against a real Azure account from this guide.

## Upgrades: dedicated owner and legacy temporary credentials

Fresh installs use `hoopdb_owner`, which has neither `SUPERUSER` nor
`CREATEROLE`, for every migration and bootstrap Job. Ownership transfer for
older `hoop`-owned installs is a follow-up under #480. On those installs the
upgrade first copies the administrator URL to `hoopdb-admin-jobs`. The two old
keys remain until Helm, every affected Job and all Deployments succeed, so the
previous revision can still roll back. The successful flow then removes both
old keys and deletes the temporary Secret. Long-running workloads never
reference the administrator URL.

Fetch the new release into a new directory, not `release`: `gh release
download` will not overwrite the files from the install. Set the new tag and
its chart version (the `agent-relay-<version>.tgz` asset):

```sh
NEW_TAG=agent-relay-<version>; CHART_VERSION=<chart version>; NEW_DIR="$NEW_TAG"
mkdir "$NEW_DIR" && gh release download "$NEW_TAG" -R AgentWorkforce/infra -D "$NEW_DIR" \
  && (cd "$NEW_DIR" && shasum -a 256 -c --quiet SHA256SUMS && tar -xzf "agent-relay-$CHART_VERSION.tgz") \
  && sed 's#__IMAGE_MIRROR_ROOT__/##' "$NEW_DIR/release-images.values.yaml" > release-images.values.yaml \
  && CHART="$NEW_DIR/agent-relay-$CHART_VERSION.tgz"
```

**Done when:** it prints nothing (`--quiet` reports only checksum failures)
and `echo "$CHART"` names the new chart package. Then:

```sh
# Prints every Job in the selected release. This includes migrate, search
# bootstrap, output-facts bootstrap, and future release Jobs.
release_jobs() {
  helm -n agent-relay get manifest agent-relay \
    | yq -N -r 'select(.kind == "Job") | .metadata.name' \
    | sort -u
}

# 1. Classify the saved layout without changing an existing role graph.
if ! bash postgres-setup.sh pre; then
  echo "database setup/classification failed; Helm was not run" >&2
  exit 1
fi

admin_jobs_prepared=false
cleanup_admin_jobs() {
  $admin_jobs_prepared || return 0
  bash postgres-setup.sh delete-admin-jobs
}
trap 'cleanup_admin_jobs || true' EXIT
trap 'cleanup_admin_jobs || true; exit 130' INT
trap 'cleanup_admin_jobs || true; exit 143' TERM

# Existing hoop-owned installs only: create one short-lived administrator Job Secret.
if [ "$(cat ~/.agent-relay-install/hoopdb-layout)" = legacy-admin ]; then
  admin_jobs_prepared=true
  if ! bash postgres-setup.sh prepare-admin-jobs; then
    echo "temporary administrator Job Secret preparation failed; Helm was not run" >&2
    exit 1
  fi
fi

# Fail before Helm changes anything if the selected layout's Secret is absent.
if [ "$(cat ~/.agent-relay-install/hoopdb-layout)" = legacy-admin ]; then
  if ! kubectl -n agent-relay get secret hoopdb-admin-jobs >/dev/null; then
    echo "temporary administrator Job Secret could not be read; Helm was not run" >&2
    exit 1
  fi
fi

# 2. Upgrade, and wait for every Job that reads the temporary Secret.
upgrade_ok=false
if helm upgrade agent-relay "$CHART" --namespace agent-relay \
    -f "$NEW_DIR/agent-relay/values-eks.yaml" -f values.yaml \
    -f ~/.agent-relay-install/hoopdb-layout-values.yaml \
    -f release-images.values.yaml --wait --wait-for-jobs --timeout 25m; then
  upgrade_ok=true
  JOBS="$(release_jobs)"
  [ -n "$JOBS" ] || upgrade_ok=false
  while $upgrade_ok && IFS= read -r JOB; do
    kubectl -n agent-relay wait --for=condition=complete "job/$JOB" --timeout=10m \
      || upgrade_ok=false
  done <<<"$JOBS"
  $upgrade_ok && kubectl -n agent-relay rollout status deploy --timeout=10m \
    || upgrade_ok=false
fi

# 3. Existing installs: only a fully successful upgrade removes the old keys.
if $upgrade_ok && [ "$(cat ~/.agent-relay-install/hoopdb-layout)" = legacy-admin ]; then
  bash postgres-setup.sh remove-legacy-secret-keys || upgrade_ok=false
fi

# Always delete the temporary copy, including after a failed upgrade.
cleanup_ok=true
cleanup_admin_jobs || cleanup_ok=false
admin_jobs_prepared=false
trap - EXIT INT TERM
$upgrade_ok || { echo "upgrade or a temporary-credential Job failed" >&2; exit 1; }
$cleanup_ok || { echo "temporary hoopdb-admin-jobs Secret was not deleted; run: bash postgres-setup.sh delete-admin-jobs" >&2; exit 1; }
echo "upgrade ok"
```

For a dedicated-owner install, `delete-admin-jobs` is harmless because the
Secret is absent. For a legacy install, the failed path deletes only the
temporary Secret; the old long-lived keys stay available to the previous Helm
revision. Fix the cause and start again at step 1. The successful path removes
the old keys only after every Job and Deployment is ready. Ownership transfer
for legacy installs is a follow-up under #480.

If an earlier attempt left a failed bootstrap Job, delete it before retrying.
A Job's pod template is immutable, so Helm does not rerun it. Define
`release_jobs` (above) in your shell, then:

```sh
release_jobs | while IFS= read -r JOB; do kubectl -n agent-relay delete job "$JOB"; done
```

Then run steps 1 to 3 with the same release. Existing-install ownership
transfer remains a follow-up under #480.

## AKS receipts upgrade qualification

The
[coordinated receipt patch](https://agentrelay.com/docs/self-hosting/upgrades#coordinated-receipt-patch-before-a-suite-release)
moves an existing install to **Relaycast 12.10.0** (SQLite migration
`0081_delivery_confirmation.sql`) and **Control 0.5.24** (migrations `0050`
and `0051`) without changing its chart. It was qualified on AKS, SQLite
backend, from this starting point:

| | |
|---|---|
| Starting release | agent-relay-2026.11.8 (chart agent-relay 0.7.15): Relaycast 12.8.0 (`sha256:ab9dd678…`), Control 0.5.23 (`sha256:46e2cb51…`). The newest whole release without the pair; 2026.11.9 is the first that contains it. |
| Install | Steps 1 to 7 of this guide with this guide's `values.yaml`, `postgres-*` files and the release's `values-eks.yaml`. No edge (Traefik, `ingress.yaml`): checks ran through `kubectl port-forward`. |
| Cluster | AKS 1.36, East US, two Standard_D4s_v4 nodes, default StorageClass |
| Patch overlay | `receipt-images.values.yaml` from the upgrades page: `relaycast.image.digest` `sha256:ec062ef9…` (12.10.0) and `relay-control.image.digest` `sha256:d1b6ca95…` (0.5.24), passed last |

What the patch does on this install:

- The render with the overlay last differs from the deployed manifest only in
  the `relaycast` and `relay-control` images and the Control migration Job
  name (`relay-control-migrate-<identity>`).
- The `search-indexer-bootstrap` Job keeps its name, so
  [Upgrades: dedicated owner and legacy temporary credentials](#upgrades-dedicated-owner-and-legacy-temporary-credentials)
  does not apply to this patch.
- Relaycast 12.8.0 has already applied `0082` to `0084`. 12.10.0 applies the
  missing `0081` at startup: `deliveries.accepted_at`, `replied_at`,
  `reply_message_id` and `messages.reply_to_message_id`.
- Messages sent before the patch stay readable. Their receipt lookup answers
  `confirmation: available` with the row's existing state (`queued`).

### Backup (both stores, writers stopped)

```sh
kubectl -n agent-relay scale deploy/relaycast deploy/relay-control --replicas=0
# scale returns before the pods exit: wait until neither writer has a pod left
for d in relaycast relay-control; do
  sel="$(kubectl -n agent-relay get deploy/$d -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
  until [ -z "$(kubectl -n agent-relay get pods -l "${sel%,}" -o name)" ]; do sleep 2; done
done
PRIMARY="$(kubectl -n agent-relay get cluster.postgresql.cnpg.io hoopdb -o jsonpath='{.status.currentPrimary}')"
# Control: its own database on the HoopDb cluster
kubectl -n agent-relay exec "$PRIMARY" -c postgres -- pg_dump -Fc -d relaycontrol > relaycontrol.dump
# Relaycast: the data directory of the relaycast-data PVC, through a pod that
# mounts the claim (uid 1000, the Relaycast image, command sleep)
kubectl -n agent-relay exec <helper pod> -- tar -C /data --exclude=lost+found -cf - . > relaycast-data.tar
# Optional second copy: an incremental snapshot of the PV's managed disk
az snapshot create -g <resource group> -n <name> --source <disk ID of the PV> --incremental true
kubectl -n agent-relay scale deploy/relaycast deploy/relay-control --replicas=1
```

Delete the helper pod before scaling Relaycast back: the volume is
ReadWriteOnce. With Relaycast stopped cleanly the directory holds only
`relaycast.db` (the WAL is checkpointed). The disk ID is the PV's
`spec.csi.volumeHandle`.

### Restore (both stores, back to the starting release)

```sh
kubectl -n agent-relay scale deploy/relaycast deploy/relay-control --replicas=0
# scale returns before the pods exit: wait until neither writer has a pod left
for d in relaycast relay-control; do
  sel="$(kubectl -n agent-relay get deploy/$d -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
  until [ -z "$(kubectl -n agent-relay get pods -l "${sel%,}" -o name)" ]; do sleep 2; done
done
kubectl -n agent-relay exec -i "$PRIMARY" -c postgres -- dropdb --if-exists relaycontrol
kubectl -n agent-relay exec -i "$PRIMARY" -c postgres -- pg_restore --create --exit-on-error -d postgres < relaycontrol.dump
# helper pod on relaycast-data, as for the backup
kubectl -n agent-relay exec <helper pod> -- rm -f /data/relaycast.db /data/relaycast.db-wal /data/relaycast.db-shm
kubectl -n agent-relay exec -i <helper pod> -- tar -C /data -xf - < relaycast-data.tar
kubectl -n agent-relay delete pod <helper pod>
# The original chart and values files, in the original order, without the overlay
helm upgrade agent-relay "$CHART" --namespace agent-relay \
  -f release/agent-relay/values-eks.yaml -f values.yaml \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml -f release-images.values.yaml --timeout 25m
```

- `pg_restore --create` recreates the database with its owner and grants
  (`control_owner`, CONNECT for `control_api_runtime`, none for PUBLIC). A
  plain `pg_restore` into a new empty database does not restore them.
- The `tar` extract prints `Cannot utime` and `Cannot change mode` for `.` and
  exits 2: the volume root belongs to root. `relaycast.db` is restored; check it
  with `PRAGMA integrity_check`.
- The original `relay-control-migrate-<identity>` Job runs again and applies
  nothing. Relaycast 12.8.0 starts on the restored file.
- A Helm rollback alone does not undo `0081` or Control's `0050` and `0051`.
  Restore both stores from the same stopped backup.

### Evidence

Run of 2026-11-17, resource group `rg-pepsv12-aks-proof-20261117` (deleted
afterwards). Times are UTC.

| Step | Command or method | Result | IDs and times |
|---|---|---|---|
| Starting release | Release assets `release-manifest.json`, image labels | 2026.11.8 is the newest release below the pair (12.8.0 and 0.5.23); 2026.11.9 pins 12.10.0 and Control 0.5.25 | chart 0.7.15 |
| Install | Steps 1 to 7, Helm revisions 1 and 2 | Migrations completed, every pod `Running`, `finalize` printed `owner createrole: false` | 21:20:16, 21:22:17 |
| Seed | MCP `join_relay` (two hosted participants) and `send_relay_message` over a device-approved `cli:auth` bearer | Sent, `queued_unconfirmed`; `get_relay_message_status` not listed (0.5.23) | message `248558839320735744`, delivery `del_248558839320735745`, 21:24:05 |
| Pre-patch state | `_engine_migrations`, `control_schema_migrations` | 83 Relaycast migrations, no `0081`, no receipt columns; Control 51 migrations, last `0049` | 21:25:04 |
| Backup | Writers scaled to 0, `pg_dump -Fc`, data-directory `tar`, disk snapshot | Dump 307,449 bytes; `relaycast.db` 1,212,416 bytes, `integrity_check` ok, seed present | recovery ID `pepsv12-pre-20261117T212519Z`, dump `sha256:31cddf74…`, tar `sha256:5825988c…`, snapshot `snap-pepsv12-pre-20261117T212519Z-relaycast`, 21:25:19 to 21:29:56 |
| Attestations | `gh attestation verify … --owner AgentWorkforce` for both digests | Both pass, SLSA v1 provenance | relaycast `fd101954`, relay-control `edad6432`, 21:10:54 |
| Render review | `helm template` with the overlay last, compared with `helm get manifest` | Only the two images and the Control migration Job name changed | `relay-control-migrate-ee5b1a3c` → `-69fced99` |
| Patch | `helm upgrade` with the original chart and values, overlay last (Helm revision 3) | Control Job applied `0050`, `0051`; Relaycast applied `0081` at startup; both Deployments ready | 21:30:16 to 21:31:02 |
| Schema | `_engine_migrations`, `pragma table_info` | `0081_delivery_confirmation.sql` recorded (84 migrations), the four columns present | `0081` applied 21:31:00 |
| Receipts tool | MCP `tools/list` | `get_relay_message_status` listed | 21:31:49 |
| Old message | `read_relay_conversation`, `check_relay_inbox`, `get_relay_message_status` | Readable by sender and recipient; status `available`, state `queued` | `248558839320735744` |
| New message receipts | `send_relay_message`; recipient `check_relay_inbox` with `acknowledge`; reply with `reply_to` | `queued` → `consumed` (`accepted_at`, `acked_at`, `read_at` set) → `replied` | message `248560789369974784` 21:31:50; ack 21:31:58; reply `248560828267950080` 21:31:59 |
| Restore | Writers to 0, `dropdb` + `pg_restore --create`, data-directory extract, `helm upgrade` without the overlay (Helm revision 4) | Render identical to the install's; Control Job applied nothing; both Deployments on the 2026.11.8 digests | 21:32:26 to 21:34:17 |
| Restored state | Same queries and MCP calls | 83 Relaycast migrations, no `0081`, no receipt columns, `integrity_check` ok; Control 51 migrations, no `grok_bot_routines`; seed message readable and in the recipient's inbox; `get_relay_message_status` not listed; the pre-backup device bearer works; a new message sends | 21:34:30 to 21:34:49 |
| Snapshot | Managed disk from the snapshot, static PV, read-only mount | `integrity_check` ok, 83 migrations, seed present | 21:35:33 |

## What was not proven

- Any release other than agent-relay-2026.11.0 (patched); `values.yaml` renders
  against agent-relay-2026.11.19 but was not installed from it.
- The output facts bootstrap (step 10).
- Azure Database for PostgreSQL, Azure Blob Storage, Application Gateway.
- NetworkPolicy enforcement beyond a default install, private clusters,
  internal load balancers.
- Backup and restore and upgrades, except the receipts image patch from
  agent-relay-2026.11.8 and the restore of Control's `relaycontrol` database
  and Relaycast's SQLite volume around it
  ([AKS receipts upgrade qualification](#aks-receipts-upgrade-qualification)).
  Not proven: whole-release upgrades, other starting releases, a restore of
  HoopDb (`hoopdb`) or the MinIO session objects, a restore into new resources,
  an Azure disk snapshot swapped in as the live Relaycast volume, and the
  receipt lookup over an OAuth MCP connection or through the edge.
- HA (every stateful component is one replica on one Azure disk).
- The desktop app, the dashboard, SSO, and titles and summaries with a live model
  (the steps were checked on GKE; see step 11).
- The Traefik edge keeps HTTP closed rather than redirecting it to HTTPS.
