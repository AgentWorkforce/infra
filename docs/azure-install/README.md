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

This guide installs release **agent-relay-2026.11.2** (chart agent-relay 0.7.7,
sessions-pipeline 0.8.32), the first release that carries
`searchIndexer.locker.credentials`. Earlier releases do not render the
indexer's MinIO keys, so its uploads are never indexed.

| File | What it is |
|---|---|
| `values.yaml` | Site values, applied after the chart package's `values-eks.yaml` and before the release's `release-images.values.yaml` |
| `postgres-tls.yaml` | cert-manager Issuers and Certificates: a 10-year CA and the server certificate for the in-cluster Postgres |
| `postgres-values.yaml` | Overrides for `deps/cnpg-cluster-values.yaml` (the pinned HoopDb Postgres) |
| `postgres-setup.sh` | Databases, roles and credential files: the `selfhosted` counterpart of `rds-setup.sh` and `cloud-sql-setup.sh` |
| `ingress.yaml` | The edge: one Traefik Ingress, the host and path rules of `scripts/selfhost/eks-alb-ingress.sh` |

## How Azure differs

| AWS (EKS guide) | Azure (this guide) | Why |
|---|---|---|
| RDS + `rds-setup.sh` (`databaseMode: rds`) | In-cluster CloudNativePG, the pinned `deps/cnpg-cluster-values.yaml`, + `postgres-setup.sh` (`databaseMode: selfhosted`) | The services image has `rds`, `cloudsql` and `selfhosted` database modes. Azure Database for PostgreSQL fits none: its admin role is neither `rds_superuser` nor `cloudsqlsuperuser`, and it is not a superuser. |
| S3 through EKS Pod Identity | The chart's bundled MinIO (`session-object-storage`) on an Azure disk, static keys from a Secret | The services speak S3 or GCS. There is no Azure Blob Locker provider. |
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
mkdir release && gh release download agent-relay-2026.11.2 -R AgentWorkforce/infra -D release
(cd release && shasum -a 256 -c SHA256SUMS && tar -xzf agent-relay-0.7.7.tgz) | tail -1
# Public GHCR images: no mirror root.
sed 's#__IMAGE_MIRROR_ROOT__/##' release/release-images.values.yaml > release-images.values.yaml
CHART=release/agent-relay-0.7.7.tgz
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
  -f release/agent-relay/values-eks.yaml -f values.yaml -f release-images.values.yaml --timeout 25m
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
  -f release/agent-relay/values-eks.yaml -f values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay wait --for=condition=complete "$(kubectl -n agent-relay get jobs -o name | grep search-indexer-bootstrap)" --timeout=10m
kubectl -n agent-relay rollout status deploy --timeout=10m
bash postgres-setup.sh finalize
```

**Done when:** three `login ok ... tls=true` lines, the bootstrap Job
completes, every pod is `Running`, and `finalize` prints `owner createrole: false`.

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
  -f release/agent-relay/values-eks.yaml -f values.yaml -f release-images.values.yaml --timeout 25m
kubectl -n agent-relay wait --for=condition=complete --timeout=2h \
  job -l app.kubernetes.io/component=output-facts-bootstrap
```

When another workspace starts uploading, change `runId` and run it again. Exit
codes and verification are in the
[sessions-pipeline chart README](../../charts/sessions-pipeline/README.md).

**Done when:** the Job completes and the workspace's Output page loads.

## What was not proven

- Any release other than agent-relay-2026.11.0 (patched); `values.yaml` renders
  against agent-relay-2026.11.2 but was not installed from it.
- The output facts bootstrap (step 10).
- Azure Database for PostgreSQL, Azure Blob Storage, Application Gateway.
- NetworkPolicy enforcement beyond a default install, private clusters,
  internal load balancers.
- Backup and restore, upgrades, HA (every stateful component is one replica on
  one Azure disk).
- The desktop app, the dashboard, SSO, titles and summaries.
- The Traefik edge keeps HTTP closed rather than redirecting it to HTTPS.
