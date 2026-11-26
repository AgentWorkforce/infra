# Install Agent Relay on your GKE cluster

**Customer handoff:** start with [GCP customer setup](README.md), the short path
for inputs, Terraform and DNS. This page is the detailed operator reference,
including alternative secret-delivery methods, optional features, upgrades,
recovery and teardown. Use the sections that match the approved installation.
Its release pins below describe this reference's release; a newer edge install
needs the compatible release selected for that deployment.

Numbered steps, in order. Copy each block, replace `<...>`, and check the
**Done when** line before moving on. This takes about 1½ hours, most of it
waiting on Google Cloud (the HTTPS certificate alone can take up to an hour).

Release: **agent-relay-2026.11.19** (infra commit `34352d40`, chart 0.7.81).

**You need:**

- Owner (or the roles in 2-SERVICE-ACCOUNTS.md, "Who runs the install") in the
  Google Cloud project, and `kubectl` admin on the GKE cluster;
- whoever manages DNS for your domain (step 6);
- the person who will be the first admin (step 15).

**The cluster:** a GKE Standard or Autopilot cluster with **Workload Identity**
on, the **HTTP load balancing** add-on on (it is by default), in a VPC with
**Private Services Access** configured (Cloud SQL and Memorystore get private
IPs from it). For nodes, plan on at least **3 × e2-standard-4 with 100 GB
disks** for Agent Relay. Small nodes with 20 GB disks run out of ephemeral
storage while pulling the images.

**No cluster or project yet?** Start with "Starting from an empty project" at
the end, then come back to step 1. Creating a project needs
`resourcemanager.projects.create` on the organization (or folder) and
`billing.user` on the billing account: ask whoever holds them early.

**Network:**

- Steps 1, 4, 5 and 6 need only Google Cloud access, not `kubectl`. Start them
  while cluster access is sorted out.
- Nothing connects to the database from your laptop. Every database step runs
  as a short-lived Job inside the cluster, so Cloud SQL needs no public IP.

## 1. Get the files

```sh
mkdir agent-relay-install && cd agent-relay-install
git clone https://github.com/AgentWorkforce/infra.git
# This guide's files (values.yaml and the scripts) come from main: the release
# tag predates them. Terraform and the chart come from the tag below.
git -C infra archive origin/main docs/gcp-install | tar -x --strip-components=2
ls 0-START-HERE.md values.yaml cloud-sql-setup.sh helm-secrets-prepare.sh first-admin.sh add-user.sh >/dev/null && echo "guide ok"
git -C infra checkout agent-relay-2026.11.19
test "$(git -C infra rev-parse HEAD)" = 34352d40aa77750f28b5fd551a6a7240a201315a && echo "release ok"
mkdir release && gh release download agent-relay-2026.11.19 -R AgentWorkforce/infra -D release
(cd release && sha256sum -c SHA256SUMS && tar -xzf agent-relay-0.7.81.tgz) | tail -1
```

**Got this guide as a gist?** Replace the `mkdir agent-relay-install ...` line
with `git clone <gist clone URL> agent-relay-install && cd agent-relay-install`,
and delete the `git -C infra archive ...` line: the gist already holds the
guide's files.

No `gh`? Download the same assets from
https://github.com/AgentWorkforce/infra/releases/tag/agent-relay-2026.11.19 into
`release/`. On macOS use `shasum -a 256 -c SHA256SUMS`.

**Installing the chart from a checkout instead of the released `.tgz`?** (A
chart newer than the pinned release, or your own change.) Build the
dependencies in this order, then use `infra/charts/agent-relay` wherever the
steps name the `.tgz` or `$CHART`:

```sh
infra/scripts/selfhost/helm-deps.sh
```

It runs `helm dependency build` for `infra/charts/sessions-pipeline`, then
`infra/charts/agent-relay`, and needs no `helm repo add`.
`sessions-pipeline` has dependencies of its own, so it goes first. Without it
the second command fails or packages a chart whose read API and workers are
not rendered. Step 7's image values then need the chart's own release, not
this guide's pins (see the note there).

Tools: `gcloud` (with `gke-gcloud-auth-plugin`), `terraform` ≥ 1.11 (or
OpenTofu), `helm` 3, `kubectl`, `jq`, `yq`, `openssl`, and
[`crane`](https://github.com/google/go-containerregistry/releases) for step 5.
Cloud Shell has everything except `crane` and Terraform ≥ 1.11.

**Helm 3, not Helm 4.** The chart is tested with Helm 3.10 or later; Helm 4 is
untested with this guide. If `helm version` prints `v4`, install Helm 3 beside
it (for example as `helm3`) and use it for steps 10, 11 and 13.

**Done when:** `guide ok`, `release ok`, then `release-notes.md: OK` (the last checksum line).

## 2. Connect to Google Cloud and the cluster

```sh
gcloud auth login && gcloud auth application-default login
gcloud config set project <project id>
gcloud services enable container.googleapis.com sqladmin.googleapis.com servicenetworking.googleapis.com \
  redis.googleapis.com pubsub.googleapis.com secretmanager.googleapis.com dns.googleapis.com \
  artifactregistry.googleapis.com compute.googleapis.com iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com
gcloud container clusters get-credentials <cluster> --location <region>   # add --internal-ip for a private endpoint
kubectl auth can-i '*' '*' --all-namespaces
gcloud container clusters describe <cluster> --location <region> \
  --format='value(workloadIdentityConfig.workloadPool,addonsConfig.httpLoadBalancing.disabled)'
gcloud container clusters describe <cluster> --location <region> \
  --format='value(networkConfig.datapathProvider,networkPolicy.enabled)'
gcloud compute addresses list --global --filter='purpose=VPC_PEERING' --format='value(name,network)'
kubectl get storageclass
```

**Done when:**

- `can-i` prints `yes`;
- the `describe` line prints `<project id>.svc.id.goog` and nothing after it
  (HTTP load balancing is not disabled);
- the `addresses` line lists a Private Services Access range on your cluster's
  VPC;
- one StorageClass is marked `(default)`;
- the second `describe` line prints `ADVANCED_DATAPATH` (Dataplane V2), or it
  ends in `True` (the NetworkPolicy add-on) and
  `kubectl -n kube-system get daemonset calico-node` shows as many ready pods
  as the cluster has nodes. The add-on enforces policies only on nodes
  recreated after it was turned on.

**Network policies must be enforced.** The chart's NetworkPolicies, and
relaygate's rule that only the gate may reach Relaycast and Sessions, have no
effect on a cluster that doesn't enforce them: GKE accepts the objects and
ignores them. Dataplane V2 can only be chosen when a cluster is created. On an
existing cluster without it, turn on the add-on, then enforcement. If the
cluster already runs other workloads, check their policies first
(`kubectl get networkpolicy -A`): policies that were ignored start to apply.

```sh
gcloud container clusters update <cluster> --location <region> --update-addons=NetworkPolicy=ENABLED
gcloud container clusters update <cluster> --location <region> --enable-network-policy
```

The second command recreates every node pool's nodes, so pods restart. Each
pool follows its own upgrade settings (`maxSurge`, `maxUnavailable`), which
decide how many nodes restart at once. Check them first, and run the command
before you install or in a maintenance window.

**Every node pool must use the GKE metadata server** for Workload Identity:
`gcloud container node-pools list --cluster <cluster> --location <region> --format='table(name,config.workloadMetadataConfig.mode)'`
shows `GKE_METADATA` for each.

**`billing account ... disabled` from Cloud Storage or Service Networking?**
Your Application Default Credentials bill API calls to a quota project without
billing. Run `gcloud auth application-default set-quota-project <project id>`,
or export `GOOGLE_CLOUD_QUOTA_PROJECT` and `CLOUDSDK_BILLING_QUOTA_PROJECT` set
to the project id.

## 3. Using your own Cloud SQL, bucket or other resources? (skip if Terraform creates them)

Follow **1-BRING-YOUR-OWN.md** instead of step 4, then continue at step 5.

## 4. Create the Google Cloud resources (Terraform, ~5 min)

This creates a regional Cloud SQL for PostgreSQL 17 instance (private IP only,
Google-managed shared CA, admin password in Secret Manager), the sessions GCS
bucket, a Standard HA Memorystore for Redis (TLS), a Pub/Sub topic and
subscription with a dead-letter queue, a private DNS zone that resolves the
Cloud SQL certificate name inside your VPC, and the Workload Identity grants
(2-SERVICE-ACCOUNTS.md lists them; all are resource-level).

```sh
cd infra/terraform/examples/gcp
cat > terraform.tfvars <<'EOF'
project_id           = "<project id>"
region               = "<cluster region, e.g. us-central1>"
name                 = "agent-relay"
namespace            = "agent-relay"
release_name         = "agent-relay"
network_self_link    = "projects/<project id>/global/networks/<cluster VPC>"
sessions_bucket_name = "<globally unique bucket name, e.g. acme-agent-relay-sessions>"
deletion_protection  = true
image_mirror_repository = "agent-relay-mirror"   # step 5's registry, readable by the GKE nodes
# desktop_feed_bucket_name = "<globally unique, e.g. acme-agent-relay-desktop-feed>"   # agent-relay-2026.11.9 or later, and only once the feed's signing key exists (see below)
# gke_node_service_account = "<email>"   # only if the node pool has its own service account
# kms_key_name = "projects/<p>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>"   # optional CMEK
labels = { app = "agent-relay" }
EOF
grep -n '<' terraform.tfvars
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output -json chart_values > ../../../../managed-values.json
cd -
```

**Done when:** the `grep` prints nothing, the plan shows `29 to add, 0 to
change, 0 to destroy` (5 more with `desktop_feed_bucket_name`, 2 fewer
without `image_mirror_repository`), the apply completes, and `managed-values.json` exists.

From agent-relay-2026.11.9, `desktop_feed_bucket_name` gives the
desktop app a signed update feed in your project: a private bucket, and a service account relay-control uses to write
releases there and sign download links. `managed-values.json` carries its
settings into step 11; if your `values.yaml` sets `relay-control.extraEnv` or
`relay-control.serviceAccount.annotations`, copy the feed entries from
`terraform output desktop_feed` into them. Earlier releases have neither the
Terraform input nor relay-control 0.5.25, so leave it commented. Agent Relay sets up
the feed's signing key with you when we build your branded desktop app.

**Uncomment it only once that signing key is in place** (the key's Secret
exists and your `values.yaml` sets `relay-control.desktopFeed.signingKeys`).
The bucket puts the feed's storage settings into `managed-values.json`, and
relay-control does not start with storage and no signer: it exits with
`SELFHOST_DESKTOP_FEED_SIGNER and SELFHOST_DESKTOP_FEED_STORAGE must be set together`
and the pod crash-loops. Adding the bucket later is this step again (5 to
add), then step 11's command.

**Already applied with the bucket, and no signing key yet?** Keep the bucket
and take the storage settings out until the key exists:

```sh
jq 'del(.["relay-control"].extraEnv)' managed-values.json > managed-values.tmp && mv managed-values.tmp managed-values.json
```

Also remove any `SELFHOST_DESKTOP_FEED_*` entries you copied into
`values.yaml`. The service account annotations can stay. When the key is in
place, write `managed-values.json` again (the `terraform output` line above)
and run step 11's command. The Terraform from the pinned release
does the same with `desktop_feed_has_signing_keys = false` in
`terraform.tfvars`: the output then leaves the storage settings out. Outputs
change only on apply, so after adding or removing that line run
`terraform plan` and `terraform apply` before writing `managed-values.json`
again.

**Terraform state.** The example has no `backend` block, so the state stays in
a local file. To keep it in Cloud Storage, create a private, versioned bucket
and add a backend before `terraform init`:

```sh
gcloud storage buckets create gs://<project id>-tfstate --location <region> \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://<project id>-tfstate --versioning
printf 'terraform {\n  backend "gcs" {}\n}\n' > backend_override.tf
terraform init -backend-config="bucket=<project id>-tfstate" -backend-config="prefix=agent-relay"
```

Either way, keep the state: upgrades and teardown need it.

- **`Error 403 ... servicenetworking`** or **`no private services access
  connection`:** the VPC has no Private Services Access. Your network team
  configures it on the cluster's VPC; then apply again.
- **CMEK:** grant the Cloud SQL, Cloud Storage and Pub/Sub service agents
  `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key first
  (2-SERVICE-ACCOUNTS.md). To use your own keys for everything, and to
  encrypt Kubernetes Secrets with one (recommended), see
  REGULATED-PROFILE.md.

## 5. Mirror the images to Artifact Registry

Copy the eight release images, by digest, into the registry step 4 created. Run
this from **Cloud Shell or a VM in Google Cloud**: from there it takes about a
minute; from a laptop it can take half an hour.

```sh
REGION=<region>
export MIRROR_ROOT=$(terraform -chdir=infra/terraform/examples/gcp output -raw image_mirror_root)
gcloud auth print-access-token | crane auth login $REGION-docker.pkg.dev -u oauth2accesstoken --password-stdin
for ref in $(jq -r '.images[].ref' release/release-manifest.json); do
  crane copy "$ref" "$MIRROR_ROOT/${ref%@*}"
  [ "$(crane digest "$MIRROR_ROOT/$ref")" = "${ref#*@}" ] && echo "ok ${ref%@*}"
done
sed "s|__IMAGE_MIRROR_ROOT__|$MIRROR_ROOT|g" release/release-images.values.yaml > release-images.values.yaml
grep -c "$MIRROR_ROOT" release-images.values.yaml
```

The GKE **node service account** pulls these images. Step 4 granted it
`roles/artifactregistry.reader` on this repository only: the project's default
Compute Engine service account, or `gke_node_service_account`. Check which
account your node pool uses:

```sh
gcloud container node-pools list --cluster <cluster> --location $REGION --format='value(name,config.serviceAccount)'
```

`default` means the default Compute Engine service account. If it names
another account, set `gke_node_service_account` to it and apply step 4 again.
In a new project nothing else grants that read, and every pull fails with
`403` (step 8's Job is the first pod that pulls).

**Done when:** `MIRROR_ROOT` is not empty, eight `ok` lines, and the `grep -c`
line prints a number above 10.

**Using a registry Terraform doesn't manage?** Leave `image_mirror_repository`
out of step 4, create the repository yourself, set
`MIRROR_ROOT=$REGION-docker.pkg.dev/<project id>/<repository>`, and grant the
node service account `roles/artifactregistry.reader` on it (2-SERVICE-ACCOUNTS.md).

## 6. Reserve the IP address and point DNS at it (DNS owner)

The HTTPS certificate is a Google-managed certificate. Google issues it only
after all four names resolve to the load balancer's address, so create the
records now:

```sh
gcloud compute addresses create agent-relay-ingress --global --ip-version IPV4
gcloud compute addresses describe agent-relay-ingress --global --format='value(address)'
```

Create **A records** for `<domain>`, `api.<domain>`, `cast.<domain>` and
`history.<domain>`, all pointing at that address.

**Done when:** `getent hosts api.<domain>` (or `dig +short api.<domain>`)
prints the address, for all four names.

**CAA records** on your domain? They must allow `pki.goog` and `letsencrypt.org`.

## 7. Create the settings file

```sh
cat > settings.sh <<'EOF'
export DOMAIN=<app hostname, e.g. ar.example.com>
export ORG_ID=<stable id, e.g. org_acme: never change it>
export ORG_NAME='<organization name>'
export ADMIN_EMAIL=<first admin's email>
export GCP_PROJECT_ID=<project id>
export REGION=<region>
export MIRROR_ROOT=<region>-docker.pkg.dev/<project id>/agent-relay-mirror
export NAMESPACE=agent-relay
export HELM_RELEASE=agent-relay
export STATIC_IP_NAME=agent-relay-ingress
export SERVICES_IMAGE=$MIRROR_ROOT/ghcr.io/agentworkforce/sessions-pipeline@sha256:459104bc432c96e475352e5147e0aaeabd53f51681d4ed8e05119e8406feda7f
export PSQL_IMAGE=$MIRROR_ROOT/ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3
export INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export CHART="$INSTALL_DIR/release/agent-relay"
TF="$INSTALL_DIR/infra/terraform/examples/gcp"
PG="$(terraform -chdir="$TF" output -json postgres)"
export CLOUD_SQL_INSTANCE="$(jq -r '.connection_name | split(":")[2]' <<<"$PG")"
export CLOUD_SQL_HOST="$(jq -r .dns_name <<<"$PG")"
export CLOUD_SQL_ADMIN_USER="$(jq -r .admin_username <<<"$PG")"
export CLOUD_SQL_ADMIN_SECRET_ID="$(jq -r .admin_password_secret_id <<<"$PG")"
export CLOUD_SQL_CA_SHA256="$(jq -r '.["sessions-pipeline"].worker.postgresCa.sha256' "$INSTALL_DIR/managed-values.json")"
export SESSIONS_BUCKET="$(jq -r '.["sessions-pipeline"].worker.locker.bucket' "$INSTALL_DIR/managed-values.json")"
unset PG TF
EOF
source settings.sh
bash -c 'source ./settings.sh; for v in DOMAIN ORG_ID ORG_NAME ADMIN_EMAIL GCP_PROJECT_ID REGION MIRROR_ROOT CLOUD_SQL_INSTANCE CLOUD_SQL_HOST CLOUD_SQL_ADMIN_USER CLOUD_SQL_ADMIN_SECRET_ID CLOUD_SQL_CA_SHA256 SESSIONS_BUCKET; do [ -n "${!v}" ] && [ "${!v}" != null ] && [[ "${!v}" != *"<"* ]] || echo "MISSING: $v"; done; echo "settings checked"'
```

**`SERVICES_IMAGE`, `PSQL_IMAGE` and `agent-relay-0.7.81.tgz` belong to the
pinned release,** agent-relay-2026.11.19 (chart 0.7.81). Installing another
release or chart? Don't reuse these digests: the Jobs in steps 8, 13 and 16
would run an older services image than the workloads. Read the three values
from that release's own assets in `release/` (step 1, with its tag):

```sh
ls release/agent-relay-*.tgz
jq -r '.images[] | select(.name == "sessions-pipeline" or .name == "sessions-migration-postgresql") | "\(.name) \(.ref)"' release/release-manifest.json
```

`SERVICES_IMAGE` is `$MIRROR_ROOT/` followed by the `sessions-pipeline` ref,
`PSQL_IMAGE` is `$MIRROR_ROOT/` followed by the `sessions-migration-postgresql`
ref, and the `.tgz` name replaces `agent-relay-0.7.81.tgz` in steps 11, 13 and
16.

A chart from a checkout (step 1) has no release assets. Read the same two
images from the checkout, for the release whose images you run, and mirror
them (step 5) before use:

```sh
jq -r '.pins["sessions-pipeline"] | "\(.repository)@\(.digest)"' infra/releases/<release tag>/pins.json
grep -m1 -o 'ghcr.io/cloudnative-pg/postgresql[^ ]*' infra/charts/sessions-pipeline/values.yaml
```

The second line prints `repository:tag@sha256:...`; `PSQL_IMAGE` takes it
without the tag (`repository@sha256:...`), as step 5 mirrors by digest.

**Brought your own resources (step 3)?** Replace the six lines between `PG=`
and `unset` with the values from 1-BRING-YOUR-OWN.md.

**Done when:** only `settings checked` prints.

**In any new terminal,** first run `cd agent-relay-install && source settings.sh`.

## 8. Set up the databases

```sh
bash cloud-sql-setup.sh pre
```

Terraform pre-creates an otherwise empty `hoopdb`. The script proves that
database has no `sessions` schema or HoopDb roles before it activates it. On
later setup and upgrade runs, an administrator-owned database with either kind
of state is always treated as a legacy install and is never converted in place.

It creates the namespace, the `cloud-sql-ca` ConfigMap, the three databases
and their roles (in a Job inside the cluster), and writes every database
credential to `~/.agent-relay-install` (mode 0700). It reads the Cloud SQL
admin password from Secret Manager and never prints it.

For a fresh install, HoopDb is owned by the plain `hoopdb_owner` login; both
long-lived migration/bootstrap keys use that URL. The Cloud SQL administrator
is used only by these one-off setup Jobs and is never stored in a Kubernetes
Secret. A rerun recognizes an older administrator-owned HoopDb and leaves its
objects and legacy role edges unchanged. Before a legacy upgrade or guide Job,
run `cloud-sql-setup.sh prepare-admin-jobs`. Keep the old long-lived keys until
Helm, every affected Job and all Deployments succeed. On success run
`cloud-sql-setup.sh remove-legacy-secret-keys`; on success or failure always
delete the temporary copy with `cloud-sql-setup.sh delete-admin-jobs`. A failed
upgrade can then roll back to the previous revision without reconstructing its
credentials.

**Done when:** it ends with `pre done`, after `tls: true` and
`extensions: btree_gin,pg_trgm,plpgsql,vector`.

Copy `~/.agent-relay-install` to your secret store: it holds the database
passwords. With Secret Manager, for example:

```sh
tar -C ~ -czf - .agent-relay-install | gcloud secrets create agent-relay-install-files \
  --project $GCP_PROJECT_ID --replication-policy automatic --labels app=agent-relay --data-file=-
```

Later copies add a version instead: `gcloud secrets versions add agent-relay-install-files --project $GCP_PROJECT_ID --data-file=-`.

- **It waits about 10 minutes, then says the Job did not succeed:** look at
  the Job's pod (`kubectl -n $NAMESPACE describe pod -l job-name=agent-relay-cloud-sql-pre`).
  `ImagePullBackOff` or `403 Forbidden` means the node service account can't
  read the mirror: check it as in step 5, then run `pre` again. Nothing was
  written to Cloud SQL, and the script recreates its Job.
- **`differs from CLOUD_SQL_CA_SHA256`:** `managed-values.json` is from an
  older apply. Rerun the last command of step 4, then `source settings.sh`.
- **The Job is evicted (`low on resource: ephemeral-storage`):** the nodes'
  disks are too small (see "The cluster" at the top).
- Run `pre` **once**, before step 11. After step 13 it refuses to run again
  (by design, and nothing changes).

## 9. Fill in values.yaml

```sh
sed -i.orig -e "s|__NAMESPACE__|$NAMESPACE|g" -e "s|__ORG_ID__|$ORG_ID|g" \
  -e "s|__ORG_NAME__|$ORG_NAME|g" -e "s|__ADMIN_EMAIL__|$ADMIN_EMAIL|g" -e "s|__DOMAIN__|$DOMAIN|g" \
  -e "s|__REGION__|$REGION|g" -e "s|__SESSIONS_BUCKET__|$SESSIONS_BUCKET|g" \
  -e "s|__STATIC_IP_NAME__|$STATIC_IP_NAME|g" values.yaml
grep -n '__[A-Z_]*__' values.yaml
```

**Done when:** the only line printed is `__LLM_MODEL__`. That one is set later,
when you turn on titles and summaries (step 16).

**Optional: co-branding.** The product stays Agent Relay; your logo goes beside
it. The sign-in page shows your square mark under the Agent Relay lockup, and
the dashboard shows one wide image with both logos. Put both PNGs in a
ConfigMap before step 11:

```sh
kubectl -n $NAMESPACE create configmap relay-brand \
  --from-file=mark.png=<your square mark>.png --from-file=cobrand.png=<Agent Relay + your logo>.png
```

Then uncomment the three "Optional co-branding" blocks in `values.yaml`
(`global.branding`, `relay-control.login`, `relay-webapp.customerProfile`) and
fill in their placeholders. For a branded desktop app,
`customerProfile.desktop` takes that build's link scheme and site.
`$CHART/values-branding-example.yaml` explains each value.

## 10. Create the secrets

Pick **one** of the four ways.

**a. Plain `kubectl`:**

```sh
S=~/.agent-relay-install/secret-files
( umask 077
for k in selfhost-bootstrap-token selfhost-setup-key relaycast-internal-secret \
         relaycast-workspace-bootstrap-secret relaycontrol-introspect-secret session-read-api-secret \
         selfhost-encryption-key; do
  [ -s "$S/agent-relay-secrets/$k" ] || openssl rand -hex 32 | tr -d '\n' > "$S/agent-relay-secrets/$k"
done
[ -s "$S/agent-relay-secrets/SUMMARY_MASTER_KEYS" ] || printf 'k1:%s' "$(openssl rand -hex 32)" > "$S/agent-relay-secrets/SUMMARY_MASTER_KEYS"
cp "$S/agent-relay-secrets/relaycontrol-introspect-secret" "$S/agent-relay-ingest-edge-runtime/introspect-secret" )
put_secret() { # create the Secret, or replace it in place; never kubectl apply, which copies
               # every value into a last-applied annotation (replace also drops an old one)
  if kubectl -n $NAMESPACE get secret "$1" >/dev/null 2>&1; then
    kubectl -n $NAMESPACE create secret generic "$@" --dry-run=client -o yaml | kubectl replace -f -
  else
    kubectl -n $NAMESPACE create secret generic "$@"
  fi
}
for name in agent-relay-secrets agent-relay-read-api agent-relay-ingest-edge-runtime \
            search-indexer-runtime search-indexer-owner; do
  put_secret "$name" --from-file="$S/$name"
done
```

**Done when:** five lines that end in `created` (`replaced` on a rerun). Copy `~/.agent-relay-install`
to your secret store again (step 8 shows how): it now holds the encryption keys.

These Secrets include the database-owner URL. A legacy administrator-owned
install also creates a provider-administrator URL in temporary
`hoopdb-admin-jobs` while migration/bootstrap Jobs run. Before other people
get access to the cluster, restrict who can read Secrets in this namespace:
[selfhost-secret-access.md](../selfhost-secret-access.md).

**b. helm-secrets with SOPS** (every secret in one encrypted values file, for
example encrypted with a Cloud KMS key):

```sh
bash helm-secrets-prepare.sh
sops --encrypt --gcp-kms projects/<p>/locations/<loc>/keyRings/<ring>/cryptoKeys/<key> secrets.yaml > secrets.enc.yaml && rm secrets.yaml
helm secrets upgrade --install agent-relay-secrets ./agent-relay-secrets-chart \
  --namespace $NAMESPACE -f secrets.enc.yaml
kubectl -n $NAMESPACE get secrets
```

**Done when:** the same five Secrets are listed. Commit `secrets.enc.yaml` and
`agent-relay-secrets-chart/` wherever you keep encrypted config.

**c. vals with Google Secret Manager** (the values live in Secret Manager;
`secrets.yaml` holds only references and is safe to commit):

```sh
VALS_GCPSM=$GCP_PROJECT_ID bash helm-secrets-prepare.sh
helm secrets --backend vals upgrade --install agent-relay-secrets ./agent-relay-secrets-chart \
  --namespace $NAMESPACE -f secrets.yaml
```

vals reads Secret Manager with Application Default Credentials (`gcloud auth
application-default login` on a laptop; Workload Identity or the VM's service
account in CI) and needs `roles/secretmanager.secretAccessor` on the secrets.
This stores 19 secrets named `agent-relay--<Secret>--<key>` in Secret Manager;
`secrets.yaml` holds only `ref+gcpsecrets://...` references. If you run vals
your own way, `vals eval -f secrets.yaml` resolves the same file.

**d. External Secrets Operator with Google Secret Manager** (the values live
in Secret Manager and the cluster syncs them; nothing secret passes through
Helm).

Option d needs the `agent-relay` chart 0.7.57 or later. The release this guide
installs (chart 0.7.81) supports it. With an older chart, Helm would ignore the
settings without an error, create no Secret, and the pods would never start.

You also need [External Secrets Operator](https://external-secrets.io)
installed in the cluster with the `external-secrets.io/v1` API. This path is
covered by render tests; it has been proven on AWS (SSM), not yet on a live
GKE install.

```sh
# 1. Put the 19 generated values in Secret Manager (the same names as c).
#    Run cloud-sql-setup.sh pre first: on a fresh install its two HoopDb owner
#    files contain hoopdb_owner URLs. The Cloud SQL administrator URL is never
#    copied into Secret Manager or an ExternalSecret.
VALS_GCPSM=$GCP_PROJECT_ID bash helm-secrets-prepare.sh && rm -f secrets.yaml
# 2. A ServiceAccount for ESO to read them as, and its access (Workload Identity, no key).
kubectl -n $NAMESPACE create serviceaccount agent-relay-external-secrets
NUMBER=$(gcloud projects describe $GCP_PROJECT_ID --format='value(projectNumber)')
MEMBER="principal://iam.googleapis.com/projects/$NUMBER/locations/global/workloadIdentityPools/$GCP_PROJECT_ID.svc.id.goog/subject/ns/$NAMESPACE/sa/agent-relay-external-secrets"
for s in $(gcloud secrets list --project $GCP_PROJECT_ID --filter='name~/agent-relay--' --format='value(name)'); do
  gcloud secrets add-iam-policy-binding "$s" --project $GCP_PROJECT_ID \
    --member "$MEMBER" --role roles/secretmanager.secretAccessor >/dev/null
done
# 3. Fill in the settings and add them to values.yaml, so every later helm
#    command in this guide carries them.
GKE_CLUSTER=<cluster name>
sed -e "s/__GCP_PROJECT_ID__/$GCP_PROJECT_ID/g" -e "s/__REGION__/$REGION/g" \
  -e "s/__GKE_CLUSTER__/$GKE_CLUSTER/g" external-secrets-values.yaml | grep -v '^#' >> values.yaml
grep -n '__[A-Z_]*__' values.yaml; grep -c '^externalSecrets:' values.yaml
```

**Done when:** the first `grep` prints nothing and the second prints `1`.

The settings must be in **every** `helm upgrade` of this install, which is
why they go into `values.yaml` and not a separate file: Helm does not keep
values from the previous command, and an upgrade without them removes the
five ExternalSecrets and, with them, the five Secrets. After the install
(step 11):

```sh
kubectl -n $NAMESPACE get secretstore,externalsecret
```

shows the store `Valid` and five ExternalSecrets `SecretSynced`. Pods that
started before their Secret existed wait in `CreateContainerConfigError` and
start by themselves once it does.

- **`SecretSyncedError` with `PermissionDenied`:** the ServiceAccount has no
  access to that secret. Run the `for` loop again; it also covers secrets
  added since.
- **A value changed in Secret Manager** reaches the Secret within an hour
  (`refreshInterval`); restart the pods that use it.
- **Do not rotate `hoopdb_owner` by changing only Secret Manager.** There is no
  supported helper yet that atomically changes the database login, saved setup
  state, and both owner URLs. Follow the current limitation and verification
  guidance in [Database Secret access](../selfhost-secret-access.md#6-also-worth-doing).
- **Existing administrator-owned install:** the first upgrade uses the
  temporary `hoopdb-admin-jobs` Secret. To remove the old long-lived keys from
  ESO-managed Secrets, first remove their mappings from the `values.yaml` used
  by every later Helm command (the template remains unchanged for fresh installs):

  ```sh
  yq -i '
    del(.externalSecrets.secrets.agent-relay-secrets.data.HOOPDB_MIGRATION_URL) |
    del(.externalSecrets.secrets.search-indexer-owner)
  ' values.yaml
  ```

  `search-indexer-owner` has no other keys, so remove its whole values entry;
  leaving an empty `data` map makes chart validation refuse the upgrade. Apply
  that values file with the successful upgrade, then remove the remaining
  `agent-relay-secrets` mapping from its live ExternalSecret and delete both
  old values from Secret Manager. Wait for reconciliation; do not patch the
  generated Kubernetes Secrets. Delete `hoopdb-admin-jobs` only after the
  upgrade Jobs, Deployments, and this store-side cleanup succeed. Do not append
  `external-secrets-values.yaml` to this existing install again: it would
  restore the removed mappings.
- **`helm uninstall` deletes these five Secrets** (ESO owns them). The values
  stay in Secret Manager.

- **Already ran (a)?** Delete those five Secrets first, so helm can own them.
- **`could not find default credentials`?** Run `gcloud auth application-default login`,
  then **delete `secrets.yaml.dec`** before retrying: helm-secrets reuses that
  file, and a failed run leaves it empty, which installs empty Secrets.

## 11. Install with Helm

```sh
helm upgrade --install $HELM_RELEASE "$INSTALL_DIR/release/agent-relay-0.7.81.tgz" --namespace $NAMESPACE \
  -f "$CHART/values-gcp.yaml" -f "$CHART/values-gcp-native.yaml" \
  -f "$INSTALL_DIR/managed-values.json" -f "$INSTALL_DIR/values.yaml" \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml \
  -f "$INSTALL_DIR/release-images.values.yaml" --timeout 25m
```

The order matters: the two GCP profiles, Terraform's managed services, your
site values, the setup script's HoopDb layout, then the release images last.

### Built-in relaygate, sessions-only (agent-relay chart 0.7.77 or later)

The recommended setup puts relaygate in front of History: the history host
goes through relaygate, the cast host stays on Relaycast
([relaygate](../self-hosted-relaygate.md#built-in-sessions-only)). It needs a
release whose chart is agent-relay **0.7.77 or later**; the chart this guide
pins (0.7.81) meets that. With an older chart, which has no sessions-only
mode, skip this subsection.

1. Create the admin Secret (used once, for the session adopt):

   ```sh
   kubectl -n $NAMESPACE get secret relaygate-admin >/dev/null 2>&1 || \
     openssl rand -hex 32 | tr -d '\n' | kubectl -n $NAMESPACE create secret generic relaygate-admin --from-file=token=/dev/stdin
   ```

2. Add the site values to the end of `values.yaml` (your domain, org and
   admins; the chart pins the relaygate image):

   ```yaml
   relaygate:
     policy:
       controlPrincipals:   # readerKinds need relay-control 0.5.38+ (see the relaygate guide)
         - { match: { orgIds: [<org id>], emails: [<admin email>] }, gid: 33 }
         - { match: { orgIds: [<org id>] }, gid: 11 }
     proxy:
       sessionsUrl: https://history.<domain>
       sessionsHosts: [history.<domain>]
       sessionsCorsOrigins: [https://<domain>]
     control:
       sessionIngestAudience: https://history.<domain>
     secrets:
       sessionsInternalSecret: { name: agent-relay-secrets, key: session-read-api-secret }
   ```

3. Add `-f "$CHART/values-gcp-relaygate.yaml"` right after
   `-f "$CHART/values-gcp-native.yaml"` in **every** `helm upgrade` of this
   install, this one and all later ones. An upgrade without it turns the gate
   off and restores direct History routes.
4. An install that already has sessions adopts them after the upgrade, dry run
   first ([existing sessions](../self-hosted-relaygate.md#existing-sessions-adopt-them-once)).

**Done when:** it prints `STATUS: deployed`. Don't add `--wait`.

## 12. Wait for the database migrations

```sh
for j in $(kubectl -n $NAMESPACE get jobs -o name | grep -E 'relay-control-migrate|relaycast-migrate|agent-relay-worker-migrate'); do
  kubectl -n $NAMESPACE wait --for=condition=complete "$j" --timeout=20m
done
```

**Done when:** three lines say `condition met` (about 2 minutes).

**Expected:** the read API, ingest edge, search indexer and
`search-indexer-bootstrap` job fail at this point. Step 13 fixes them.

## 13. Switch on the service logins

```sh
bash cloud-sql-setup.sh post
kubectl -n $NAMESPACE rollout restart deploy/agent-relay-read-api deploy/agent-relay-ingest-edge deploy/agent-relay-search-indexer
for j in $(kubectl -n $NAMESPACE get jobs -o name | grep search-indexer-bootstrap); do kubectl -n $NAMESPACE delete "$j"; done
helm upgrade --install $HELM_RELEASE "$INSTALL_DIR/release/agent-relay-0.7.81.tgz" --namespace $NAMESPACE \
  -f "$CHART/values-gcp.yaml" -f "$CHART/values-gcp-native.yaml" \
  -f "$INSTALL_DIR/managed-values.json" -f "$INSTALL_DIR/values.yaml" \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml \
  -f "$INSTALL_DIR/release-images.values.yaml" --timeout 25m
kubectl -n $NAMESPACE wait --for=condition=complete "$(kubectl -n $NAMESPACE get jobs -o name | grep search-indexer-bootstrap)" --timeout=10m
kubectl -n $NAMESPACE rollout status deploy --timeout=10m
kubectl -n $NAMESPACE get pods
```

**Done when:**

- `post done` prints after three `login ok ... tls=true` lines;
- the bootstrap job shows `condition met`;
- every pod is `Running` and ready (completed Jobs show `Completed`).

**`PostgresTlsConfigError` in the read API, ingest edge or indexer logs:** the
`cloud-sql-ca` ConfigMap doesn't match the pin in `managed-values.json`.
Compare `kubectl -n $NAMESPACE get cm cloud-sql-ca -o jsonpath='{.data.ca\.crt}' | sha256sum`
with `echo $CLOUD_SQL_CA_SHA256`.

## 14. Wait for the certificate and check (≤ 60 min)

```sh
kubectl -n $NAMESPACE get managedcertificate agent-relay -o jsonpath='{.status.certificateStatus}{"\n"}'
```

Repeat until it prints `Active` (what is normal while you wait is below). Then:

```sh
curl -fsS "https://api.$DOMAIN/readyz" && echo " api ok"
curl -fsS "https://cast.$DOMAIN/health" && echo " cast ok"
curl -fsS -o /dev/null -w "dashboard %{http_code}\n" "https://$DOMAIN/"
curl -s -o /dev/null -w "history %{http_code}\n" "https://history.$DOMAIN/v1/sessions"
```

**Done when:** `Active`, then `api ok`, `cast ok`, `dashboard 200` and
`history 401`.

**The Ingress can take 15 to 20 minutes to get its address** after step 11.
The certificate cannot leave `Provisioning` before that. To look:

```sh
kubectl -n $NAMESPACE get ingress
kubectl -n $NAMESPACE describe ingress | sed -n '/^Events:/,$p'
```

A `Translation failed ... no BackendConfig for service port exists` warning
on the first sync is harmless when it does not repeat: the load balancer
controller read the Services before their BackendConfigs, and a later sync
heals it by itself. Worry only if the `ADDRESS` column is still empty, or the
warning still repeats, after about 20 minutes; then send us the events.

- **Stuck in `Provisioning` for over an hour:** one of the four names does not
  resolve to the address from step 6, or a CAA record blocks Google. Fix DNS;
  the certificate retries by itself.
- **`FailedNotVisible`:** the same: DNS does not point at the load balancer yet.
- **502 for a few minutes after `Active`:** the load balancer's health checks
  are still converging. Wait 5 minutes.
- **502 on `/internal` and other closed paths is not an outage.** The chart
  routes paths that must not be public (for example
  `https://api.<domain>/internal/...`) to the `...-cast-edge-deny` Service,
  which has no endpoints on purpose. Without a Cloud Armor policy the load
  balancer answers those paths with 502, not 403 or 404. Only the four checks
  above tell you whether the install is up.

The load balancer accepts TLS 1.0 and later until it has an SSL policy. To
require TLS 1.2, add Cloud Armor, or put Cloudflare in front, see
[3-EDGE-HARDENING.md](3-EDGE-HARDENING.md) (needs chart 0.7.59 or later, which
the release this guide pins has).

## 15. First sign-in, then add users

The first admin does this **before signing in any other way**, including the
desktop app:

```sh
kubectl -n $NAMESPACE get secret agent-relay-secrets -o jsonpath='{.data.selfhost-setup-key}' | base64 -d; echo
```

1. Open `https://<domain>/login` and choose **First-time setup: enter setup
   key**.
2. Paste the key and choose a password.

**No `kubectl` from the admin's machine?** With a private control plane the
first admin often can't reach the cluster. Whoever runs the install does the
same first sign-in through the API, without the key or password ever being
shown:

```sh
bash first-admin.sh "$DOMAIN" "$GCP_PROJECT_ID" "$NAMESPACE"
```

It stores a generated password in Secret Manager as
`agent-relay-first-admin-password`, then posts it with the setup key, and
prints `first admin set`. The admin reads the password with
`gcloud secrets versions access latest --secret agent-relay-first-admin-password --project <project id>`
and signs in at `https://<domain>/login`. The setup key works once, within 24
hours: the script never retries, and it stops if the secret already exists.
A `403 csrf_rejected` means the request lacked your dashboard's origin; it is
refused before the key is read, so the key stays unused.

Two settings, both optional:

- **The API is not at `api.<app hostname>`** (your own four host names): name
  it with `API_HOST=<api hostname> bash first-admin.sh ...`. The script calls
  that host and still sends the app hostname as the origin.
- **No Secret Manager** (the API is off, or you may not create secrets there):
  `PASSWORD_FILE=<path> bash first-admin.sh ...` keeps the password in that
  new local file (mode 0600) instead; `<project id>` is then unused and can be
  `-`. The script stops if the file exists. Hand the file to the admin over a
  channel you trust, then delete it. By default the script needs
  `secretmanager.googleapis.com` and permission to create a secret in the
  project.

Then add users:

```sh
bash add-user.sh "$DOMAIN"
```

It prints a temporary password for each user; they choose their own at first
sign-in.

**Done when:** the admin is signed in to the dashboard.

## 16. Turn on titles and summaries (optional, after first sign-in)

Two workers write what the dashboard shows for a session:

- **Summaries (bob-costas)** run from the install on. By default
  (`BOB_COSTAS_MODEL: "off"`) they are **extractive**: built from the session's
  own text, with no model and no data leaving the cluster.
- **Titles and briefs (session-brief)** need a model and are off until you turn
  them on for named workspaces.

This step turns on model-written titles, briefs and summaries. It needs an API
key for the OpenAI Responses API, or an OpenAI-compatible gateway, and a model
it serves. The examples use `gpt-5.6-luna`. Session text is sent to that
endpoint.

**16a.** Store the key in the cluster (it is not echoed, and never on a
command line):

```sh
read -rs -p 'OpenAI API key: ' K; echo
printf '%s' "$K" | kubectl -n $NAMESPACE create secret generic agent-relay-llm --from-file=OPENAI_API_KEY=/dev/stdin
unset K
```

**Done when:** it prints `secret/agent-relay-llm created`. To replace the key
later, delete the Secret, run this again, then restart both workers so they
read the new key (they read it only at start, and an unchanged Helm upgrade
doesn't restart them); don't use `kubectl apply`:

```sh
kubectl -n $NAMESPACE rollout restart deploy/agent-relay-worker-session-brief deploy/agent-relay-worker-session-summary-worker
```

**16b.** Find the workspace ID. Workspaces exist only after the first sign-in
(step 15):

```sh
bash workspace-ids.sh "$DOMAIN" "$NAMESPACE"
```

It prints one line per workspace: its ID, then its name (`Default` is the one
created at install).

**Done when:** you have the ID of each workspace that should get titles and
summaries. List them explicitly: never use `*`.

**16c.** Update `values.yaml`:

```sh
export WORKSPACE_ID=<workspace id from 16b> MODEL=gpt-5.6-luna
yq -i '
  .["sessions-pipeline"].worker.nativeBrief.enabled = true |
  .["sessions-pipeline"].worker.nativeBrief.workspaceIds = [strenv(WORKSPACE_ID)] |
  .["sessions-pipeline"].worker.nativeBrief.model = strenv(MODEL) |
  .["sessions-pipeline"].worker.nativeBrief.image = {"repository": (strenv(SERVICES_IMAGE) | split("@")[0]), "digest": (strenv(SERVICES_IMAGE) | split("@")[1])} |
  .["sessions-pipeline"].worker.components["session-brief"].enabled = true |
  .["sessions-pipeline"].worker.components["bob-costas"].env = [
    {"name": "BOB_COSTAS_MODEL", "value": strenv(MODEL)},
    {"name": "OPENAI_API_KEY", "valueFrom": {"secretKeyRef": {"name": "agent-relay-llm", "key": "OPENAI_API_KEY"}}}
  ]
' values.yaml
grep -n '__LLM_MODEL__' values.yaml
```

This replaces `__LLM_MODEL__` with your model. The brief worker runs the same
services image as the rest of the release (`SERVICES_IMAGE` from step 7), named
here because the release image overlay doesn't set it. The `bob-costas` list
replaces the chart's default, so it holds only these two entries.

- **More than one workspace:** set `workspaceIds` to
  `[strenv(WORKSPACE_ID), "<another id>"]`.
- **An OpenAI-compatible gateway** instead of OpenAI: also set
  `.["sessions-pipeline"].worker.nativeBrief.baseUrl = "https://<gateway>/v1"`
  and add `{"name": "OPENAI_BASE_URL", "value": "https://<gateway>/v1"}` to the
  `bob-costas` list. Both call `<baseUrl>/responses`.

**Done when:** the `grep` prints nothing.

**16d.** Apply it, with the same files and order as step 11:

```sh
helm upgrade --install $HELM_RELEASE "$INSTALL_DIR/release/agent-relay-0.7.81.tgz" --namespace $NAMESPACE \
  -f "$CHART/values-gcp.yaml" -f "$CHART/values-gcp-native.yaml" \
  -f "$INSTALL_DIR/managed-values.json" -f "$INSTALL_DIR/values.yaml" \
  -f ~/.agent-relay-install/hoopdb-layout-values.yaml \
  -f "$INSTALL_DIR/release-images.values.yaml" --timeout 25m
kubectl -n $NAMESPACE rollout status deploy/agent-relay-worker-session-brief deploy/agent-relay-worker-session-summary-worker --timeout=10m
```

**Done when:**

- both rollouts finish (the brief worker is a new Deployment,
  `agent-relay-worker-session-brief`);
- a session uploaded after this shows a title and a summary in the dashboard;
- `kubectl -n $NAMESPACE logs deploy/agent-relay-worker-session-summary-worker | grep 'bob costas model summary'`
  shows `"outcome":"model"` with your model as `model_id` for that session.

Good to know:

- **Extractive is the fallback.** With `BOB_COSTAS_MODEL: "off"` (the default)
  summaries are extractive (`bob costas summary` logs `model_id`
  `extractive/v1`). With a model but no key, bob-costas still writes an
  extractive summary and logs `bob costas model summary fallback` with
  `"reason":"no_api_key"`. So does any failed model call, with
  `"reason":"model_failed"`.
- **Limits.** The brief worker writes at most 2000 briefs a day across the
  install and 10 per session (`nativeBrief.globalDailyCap`, `sessionDailyCap`;
  agent-relay 0.7.49 and later; 20 and 3 before), for sessions in the listed
  workspaces only. They cap model spend: past a cap new briefs are
  `rate_limited` and the dashboard shows "No summary yet" until the next UTC
  day, so raise `globalDailyCap` above your sessions per day if that happens.
  A workspace added later needs its ID added here and the upgrade run again.
  bob-costas model calls have their own caps, kept in memory per replica and
  reset each UTC day: 5000 sessions per organization
  (`BOB_COSTAS_BACKGROUND_DAILY_BUDGET`) and 20000 model attempts in all
  (`BOB_COSTAS_GLOBAL_DAILY_CAP`). Past a cap, summaries fall back to
  extractive.
- **MCP `list_session_summaries`:** `values.yaml` already sets
  `sessions-pipeline.sessionReadApi.summaries.listShortSummary: true`, so MCP
  `list_session_summaries` returns the recorded summaries (chart 0.7.15 and
  later, AgentWorkforce/infra#346).
- **Turn it off:** set `nativeBrief.enabled` and `session-brief.enabled` back to
  `false`, remove `nativeBrief.baseUrl` if you set a gateway (the chart refuses
  a `baseUrl` while the brief worker is off), and set the `bob-costas` list back
  to `[{"name": "BOB_COSTAS_MODEL", "value": "off"}]`:

  ```sh
  yq -i '
    .["sessions-pipeline"].worker.nativeBrief.enabled = false |
    del(.["sessions-pipeline"].worker.nativeBrief.baseUrl) |
    .["sessions-pipeline"].worker.components["session-brief"].enabled = false |
    .["sessions-pipeline"].worker.components["bob-costas"].env = [{"name": "BOB_COSTAS_MODEL", "value": ("off" | . style="double")}]
  ' values.yaml
  ```

  Run the `helm upgrade` from 16d, then wait for the summary worker only (the
  upgrade removes the brief worker):
  `kubectl -n $NAMESPACE rollout status deploy/agent-relay-worker-session-summary-worker --timeout=10m`.
  Then `kubectl -n $NAMESPACE delete secret agent-relay-llm`.

## 17. Turn on agent search (once, after first sign-in)

Searching Sessions for `@<agent name>` answers "The session agent index isn't
ready yet" (`501 agent_filter_not_ready` from the API) until this one-time
activation runs. It checks that every session's agent names are indexed, then
marks the index ready; later sessions are indexed as they arrive. Run it once
the first session has uploaded, or on a brand-new install with
`--fresh-install` (below).

**17a. Get the script and plan (read-only).** It runs in a pod in the
cluster as the migration owner. A fresh install reads the dedicated
`hoopdb_owner` URL from `agent-relay-secrets`; an existing administrator-owned
install must run `cloud-sql-setup.sh prepare-admin-jobs` immediately first and
set `HOOPDB_JOB_SECRET=hoopdb-admin-jobs`. Keep that temporary Secret through
both the read-only plan and the final apply in 17b; both pods reference it. The
URL never reaches your shell. The script isn't in the
services image, so this fetches it from the commit the image was built from:

```sh
REV="$(crane config "ghcr.io/agentworkforce/sessions-pipeline@${SERVICES_IMAGE#*@}" | jq -r '.config.Labels["org.opencontainers.image.revision"]')"
HOOPDB_JOB_SECRET="${HOOPDB_JOB_SECRET:-agent-relay-secrets}"
curl -fsSL -o catalog-activation.ts "https://raw.githubusercontent.com/AgentWorkforce/relayhistory-pipeline/$REV/scripts/native-agent-catalog-activation.ts"
kubectl -n $NAMESPACE create configmap agent-catalog-activation --from-file=catalog-activation.ts --dry-run=client -o yaml | kubectl apply -f -
catalog() {  # catalog --plan | catalog --apply <fingerprint>
  [ -n "$NAMESPACE" ] && [ -n "$SERVICES_IMAGE" ] || { echo "missing settings: run 'source settings.sh' (step 7) first"; return 1; }
  ARGS="$(printf ', "%s"' "$@")"
  kubectl -n $NAMESPACE delete pod agent-catalog --ignore-not-found
  kubectl -n $NAMESPACE apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: agent-catalog }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
  volumes:
    - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
    - { name: ca, configMap: { name: cloud-sql-ca } }
    - { name: script, configMap: { name: agent-catalog-activation } }
  containers:
    - name: catalog
      image: $SERVICES_IMAGE
      workingDir: /app
      command: [bun, /app/scripts/native-agent-catalog-activation.ts$ARGS]
      env:
        - { name: HOOPDB_DB_MODE, value: selfhosted }
        - { name: HOOPDB_URL, valueFrom: { secretKeyRef: { name: $HOOPDB_JOB_SECRET, key: HOOPDB_MIGRATION_URL } } }
        - { name: NODE_EXTRA_CA_CERTS, value: /etc/catalog-ca/ca.crt }
        - { name: HOME, value: /tmp }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
        - { name: ca, mountPath: /etc/catalog-ca, readOnly: true }
        - { name: script, mountPath: /app/scripts/native-agent-catalog-activation.ts, subPath: catalog-activation.ts, readOnly: true }
YAML
  t=0
  until p="$(kubectl -n $NAMESPACE get pod agent-catalog -o jsonpath='{.status.phase}')"; [ "$p" = Succeeded ] || [ "$p" = Failed ]; do
    sleep 3; t=$((t + 3))
    [ $t -lt 300 ] || { echo "agent-catalog still $p after 5 min"; kubectl -n $NAMESPACE describe pod agent-catalog | tail -20; return 1; }
  done
  kubectl -n $NAMESPACE logs agent-catalog | tail -1
  rc="$(kubectl -n $NAMESPACE get pod agent-catalog -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
  echo "exit $rc"; [ "$rc" = 0 ]
}
catalog --plan
```

**Done when:** one JSON line, then `exit 0` or `exit 2`. The plan is read-only
and safe to run any time. Its line shows `"eligible"` and a 64-character
`fingerprint`; `"eligible":false` with only `unprojected` above 0 is fine at
this point.

**17b. Pause uploads, plan, apply, resume (about a minute).** Apply only
works on a plan made while nothing writes, so stop uploads, give the indexer a
minute to catch up, then stop it too. `pause` waits until a Deployment's pods
are gone; `resume` puts back the replica counts read here:

```sh
IE="$(kubectl -n $NAMESPACE get deploy agent-relay-ingest-edge -o jsonpath='{.spec.replicas}')"
SI="$(kubectl -n $NAMESPACE get deploy agent-relay-search-indexer -o jsonpath='{.spec.replicas}')"
pause() {
  sel="$(kubectl -n $NAMESPACE get deploy "$1" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
  [ -n "$sel" ] && kubectl -n $NAMESPACE scale deploy/"$1" --replicas=0 || return 1
  until [ -z "$(kubectl -n $NAMESPACE get pods -l "$sel" -o name)" ]; do sleep 3; done
}
resume() {
  kubectl -n $NAMESPACE scale deploy/agent-relay-search-indexer --replicas=$SI
  kubectl -n $NAMESPACE scale deploy/agent-relay-ingest-edge --replicas=$IE
  kubectl -n $NAMESPACE rollout status deploy/agent-relay-search-indexer deploy/agent-relay-ingest-edge --timeout=10m
}
if [ -n "$IE" ] && [ -n "$SI" ]; then
  pause agent-relay-ingest-edge && sleep 60 && pause agent-relay-search-indexer && catalog --plan
else
  echo "couldn't read the replica counts; nothing was scaled"
fi
```

Check the plan shows `"eligible":true`, then apply that plan's fingerprint.
Writers resume and the script is removed only if the apply succeeds:

```sh
catalog --apply <fingerprint from the plan above> && resume &&
  kubectl -n $NAMESPACE delete pod/agent-catalog configmap/agent-catalog-activation
```

On a legacy administrator-owned install, only after the apply, writer resume,
and rollouts above succeed, delete the temporary copy. Do not remove the old
rollback keys here: that happens only after the first Helm upgrade through the
temporary-Secret flow succeeds, including all of its Jobs and Deployments:

```sh
cloud-sql-setup.sh delete-admin-jobs
```

After a failed attempt, run `cloud-sql-setup.sh delete-admin-jobs`; run
`prepare-admin-jobs` again before retrying either catalog pod.

**Done when:** the plan shows `"eligible":true`, the apply shows
`"activated":true` and `exit 0`, both rollouts finish, and searching Sessions
for `@<agent name>` lists sessions (or none) instead of "The session agent
index isn't ready yet".

- **Brand-new install, no sessions yet:** the plan shows `"liveRows":0` and
  `"eligible":false`. Either upload a session first, or add `--fresh-install`
  as the last argument to both: `catalog --plan --fresh-install`, then
  `catalog --apply <fingerprint> --fresh-install`. Use it only on an install
  that has never had a session, deleted ones included; anywhere else the plan
  stays ineligible.
- **It briefly pauses writers.** Uploads are refused while
  `agent-relay-ingest-edge` is at 0, and the apply itself locks the session
  index (it waits at most 1 second for those locks). Expect about a minute.
  Run it at a quiet time, and before anyone deletes a session.
- **To give up or try later:** run `resume`. Uploads stay off until you do. On
  a legacy install, delete `hoopdb-admin-jobs` after the writers recover and
  run `prepare-admin-jobs` again before retrying.
- **`unprojected` above 0 in the paused plan:** the indexer hadn't caught up.
  Run `kubectl -n $NAMESPACE scale deploy/agent-relay-search-indexer --replicas=$SI`,
  wait a minute, then `pause agent-relay-search-indexer && catalog --plan`.
- **`native_catalog_plan_changed`:** something wrote between plan and apply.
  Plan again and apply the new fingerprint.
- **`native_catalog_operation_failed` with `exit 1` from apply:** usually a
  writer still held the locks. Nothing was written and writers are still
  paused; run the same `catalog --apply ... && resume ...` line again.
- **`native_catalog_schema_validation_required`:** the pod couldn't reach the
  database, or the migrations (step 12) haven't finished.
- **Any other count above 0** (for example `unknownUsers`): run `resume` and
  send us the JSON line.

## Next

- **Before people start:** in the dashboard, under Settings › Policies, set
  what the desktop app uploads.
- **Desktop app:** install it, sign in to `https://<domain>`, run one agent
  session, and check it appears under **Sessions**. The desktop app updates
  itself from the signed feed in the `desktop_feed_bucket_name` bucket (step 4)
  once the feed's signing key is in place (Agent Relay sets it up with you; see
  step 4). Without the bucket, a newer desktop version means installing the new
  build over the old one (NOT-QUALIFIED.md item 11).
- **Search:** transcript search is stored in Cloud SQL (`search.backend:
  postgres`); there is no search cluster to run.
- **Problems:** to ask for help, send:
  - the step number;
  - the command;
  - its output;
  - `kubectl -n agent-relay get pods,jobs`.

  Never send passwords, keys, or anything from `~/.agent-relay-install`.

## What this release does not yet qualify on GKE

**Read NOT-QUALIFIED.md before a production rollout.** Item 1: GCS session
reads (`/turns`, replay, events) are fixed in 2026.11.6 and verified on a GKE
install. If you uploaded sessions on 2026.11.1 to 2026.11.5, run "Re-stamp
sessions uploaded before 2026.11.6" below once after upgrading.

## Set `trustedProxies` to 2 (installs made from an earlier copy of this guide)

Earlier copies of `values.yaml` had `relay-control.auth.trustedProxies: 1`.
The Google load balancer adds two entries to `X-Forwarded-For` (the client's
address, then its own), so with 1 the API takes the load balancer's address
as every client's address. Sign-in then works, but all users share one
per-address rate limit and one password lockout: a few wrong passwords from
anyone can lock everyone out for a while.

Check what your pods receive:

```sh
kubectl -n $NAMESPACE logs deploy/relay-webapp -c dashboard --tail 5
```

The last quoted field of each line is `X-Forwarded-For`. With the load
balancer alone it is `<your address>, <load balancer address>`: two entries.
In `values.yaml` set:

```yaml
relay-control:
  auth:
    trustedProxies: 2
```

and run step 11's `helm upgrade` again.

**A proxy or CDN in front of the load balancer** adds one more entry, so the
count is one higher. Raise it only once the load balancer refuses requests
that do not come through the proxy (for example with a Cloud Armor policy
that admits only the proxy's addresses). Until then keep 2: a caller who
connects to the load balancer directly can put any address in
`X-Forwarded-For`, and with the higher count the API would take that forged
address as the client's.

**Done when:**

```sh
kubectl -n $NAMESPACE get deploy relay-control -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SELFHOST_TRUSTED_PROXIES")].value}{"\n"}'
```

prints `2`.

## Re-stamp sessions uploaded before 2026.11.6 (upgrades only)

Releases 2026.11.1 to 2026.11.5 recorded sessions uploaded to GCS as if they
were in S3, so the read API refuses them (`501`). 2026.11.6 records new uploads
correctly; this one-off tool fixes the rows written before. A fresh install of
2026.11.6 or later doesn't need it. It changes only rows whose objects it finds in your
bucket, writes nothing in plan mode, and is safe to rerun.

Run it in a terminal where you ran `cd agent-relay-install && source settings.sh`
(step 7): it needs `NAMESPACE`, `REGION` and `SESSIONS_BUCKET` from there.
For a legacy administrator-owned install, prepare `hoopdb-admin-jobs` first,
set `HOOPDB_JOB_SECRET=hoopdb-admin-jobs`. Always run
`cloud-sql-setup.sh delete-admin-jobs` afterwards, including on failure. Keep
the old rollback keys until the first Helm upgrade through the temporary-Secret
flow, all of its Jobs, and its Deployments succeed. A
missing temporary Secret makes the pod fail before any row is changed.

```sh
IMG="$(kubectl -n $NAMESPACE get deploy agent-relay-read-api -o jsonpath='{.spec.template.spec.containers[0].image}')"
CA_SHA="$(kubectl -n $NAMESPACE get deploy agent-relay-read-api -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SESSION_POSTGRES_CA_SHA256")].value}')"
HOOPDB_JOB_SECRET="${HOOPDB_JOB_SECRET:-agent-relay-secrets}"
restamp() {  # restamp plan | restamp apply
  [ -n "$NAMESPACE" ] && [ -n "$REGION" ] && [ -n "$SESSIONS_BUCKET" ] && [ -n "$CA_SHA" ] && [ -n "$IMG" ] \
    || { echo "missing settings: run 'source settings.sh' (step 7) first"; return 1; }
  APPLY=""; [ "$1" = apply ] && APPLY=", --apply"
  kubectl -n $NAMESPACE delete pod index-restamp --ignore-not-found
  kubectl -n $NAMESPACE apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: index-restamp }
spec:
  restartPolicy: Never
  serviceAccountName: agent-relay-read-api
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
  volumes:
    - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
    - { name: ca, configMap: { name: cloud-sql-ca } }
    - { name: url, secret: { secretName: $HOOPDB_JOB_SECRET, defaultMode: 0400, items: [ { key: HOOPDB_MIGRATION_URL, path: url } ] } }
  containers:
    - name: restamp
      image: $IMG
      command: [bun, run, /app/src/session-pipeline/index-provider-restamp.ts$APPLY]
      env:
        - { name: LOCKER_PROVIDER, value: gcs }
        - { name: LOCKER_BUCKET, value: "$SESSIONS_BUCKET" }
        - { name: LOCKER_REGION, value: "$REGION" }
        - { name: SESSION_POSTGRES_TLS_PROFILE, value: custom-ca }
        - { name: SESSION_POSTGRES_CA_FILE, value: /etc/restamp-ca/ca.crt }
        - { name: SESSION_POSTGRES_CA_SHA256, value: "$CA_SHA" }
        - { name: INDEX_PROVIDER_RESTAMP_DATABASE_URL_FILE, value: /run/restamp/url }
        - { name: HOME, value: /tmp }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
        - { name: ca, mountPath: /etc/restamp-ca, readOnly: true }
        - { name: url, mountPath: /run/restamp, readOnly: true }
YAML
  t=0
  until p="$(kubectl -n $NAMESPACE get pod index-restamp -o jsonpath='{.status.phase}')"; [ "$p" = Succeeded ] || [ "$p" = Failed ]; do
    sleep 5; t=$((t + 5))
    [ $t -lt 600 ] || { echo "index-restamp still $p after 10 min"; kubectl -n $NAMESPACE describe pod index-restamp | tail -20; return 1; }
  done
  kubectl -n $NAMESPACE logs index-restamp | tail -1
  kubectl -n $NAMESPACE get pod index-restamp -o jsonpath='exit {.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
}
restamp plan
```

Check the plan's JSON line, and keep a copy of it: `restamp apply` replaces the
pod, so its output is gone afterwards. `scanned` is the rows still recorded as
S3, `proven` those whose objects are in your bucket (they will be fixed) and
`unproven` those left alone. Then apply it:

```sh
restamp apply
kubectl -n $NAMESPACE delete pod index-restamp
```

**Done when:** the last JSON line shows `"complete":true` with `restamped`
equal to the `proven` in the plan line you kept, and `exit 0`.

- **`missing settings`:** this terminal hasn't run `source settings.sh`.
- **`still Pending after 10 min`:** the `describe` output shows why (usually an
  image pull from your mirror). Fix it, then run the same command again.

- **`exit 3`:** incomplete (a page limit, or a row refused mid-run). Run
  `restamp apply` again.
- **`exit 5`:** done, but `guard_skipped` rows were kept by a database guard
  (an erase fence, or a publication still in progress). Rerunning won't change
  them; send us the JSON line.
- **`exit 2`:** misconfigured (for example `LOCKER_BUCKET` is empty). Nothing
  was read or written.
- **`exit 4`:** any other error; check `kubectl -n $NAMESPACE logs index-restamp`
  and run it again.

## Removing the install

Everything here is permanent: it deletes the database, the session data and
the load balancer. Take a Cloud SQL export or backup first if you might need
the data.

```sh
source settings.sh
helm uninstall $HELM_RELEASE -n $NAMESPACE --wait --timeout 10m
kubectl delete namespace $NAMESPACE --wait --timeout 15m
```

**Done when:** `kubectl get namespace $NAMESPACE` answers `NotFound`. This also
removes the load balancer, its certificate and the Relaycast volume.

Then the Google Cloud resources. Turn deletion protection off first: with it
on, Cloud SQL, Memorystore and the Pub/Sub topics refuse to be deleted.

```sh
cd infra/terraform/examples/gcp
sed -i.orig 's/^deletion_protection *= *true/deletion_protection  = false/' terraform.tfvars
grep -n '^deletion_protection' terraform.tfvars
terraform apply
gcloud storage rm -r -a "gs://$SESSIONS_BUCKET/**"
FEED="$(sed -n 's/^desktop_feed_bucket_name *= *"\(.*\)"/\1/p' terraform.tfvars)"
[ -z "$FEED" ] || gcloud storage rm -r -a "gs://$FEED/**"
terraform state list | grep -E '^module\.postgres\.google_sql_(database|user)\.' |
  while read -r r; do terraform state rm "$r"; done
terraform destroy
cd -
```

- **Buckets:** they are versioned, so `-a` removes every object version;
  Terraform won't delete a bucket that still holds any. The second `rm`
  empties the desktop update feed bucket, and runs only if you set
  `desktop_feed_bucket_name` in step 4.
- **Databases and admin user:** `cloud-sql-setup.sh` gave the databases to
  their own roles (`hoopdb_owner` for a fresh HoopDb), so Terraform can't drop
  them, or the bootstrap admin user with remaining dependencies, one by one
  (`must be owner of database`, `role ... cannot be
  dropped`). The `state rm` loop takes the three databases and the admin user
  out of Terraform's state only; the instance deletion that follows removes
  them with it. Run it only as part of this full teardown.

**Done when:** `terraform destroy` reports `Destroy complete!` and
`terraform -chdir=infra/terraform/examples/gcp state list | grep -v '^data\.'`
prints nothing.

Last, what Terraform didn't create:

```sh
gcloud compute addresses delete agent-relay-ingress --global
gcloud artifacts repositories delete agent-relay-mirror --location $REGION
```

- The DNS owner deletes the four A records from step 6.
- **Used `first-admin.sh` (step 15)?** Delete the password it stored, or it
  will refuse to run for a new install in this project:
  `gcloud secrets delete agent-relay-first-admin-password --project $GCP_PROJECT_ID`.
  With `PASSWORD_FILE`, delete that file instead.
- **Used vals with Secret Manager (step 10c)?** Delete its secrets:
  `gcloud secrets list --filter='name~agent-relay--' --format='value(name)' | xargs -r -n1 gcloud secrets delete --quiet`.
- Delete `~/.agent-relay-install` from wherever you copied it: the database
  passwords in it no longer work.

## Starting from an empty project

The steps above assume a GKE cluster in a VPC with Private Services Access. If
you have neither, this creates a dedicated project in a minimal shape that meets
"The cluster" at the top: private nodes, Cloud NAT for their outbound traffic,
and a public control plane open only to the addresses you list. Change the
ranges if they overlap your other networks.

```sh
P=<project id>; R=<region, e.g. us-central1>
gcloud projects create $P --organization <organization id> --labels app=agent-relay
gcloud billing projects link $P --billing-account <billing account id>
gcloud config set project $P
gcloud services enable container.googleapis.com compute.googleapis.com servicenetworking.googleapis.com \
  cloudresourcemanager.googleapis.com iam.googleapis.com storage.googleapis.com
gcloud compute networks create agent-relay-vpc --subnet-mode custom
gcloud compute networks subnets create agent-relay-subnet --network agent-relay-vpc --region $R \
  --range 10.10.0.0/20 --secondary-range pods=10.20.0.0/16,services=10.30.0.0/20 \
  --enable-private-ip-google-access
gcloud compute addresses create agent-relay-psa --global --purpose VPC_PEERING \
  --prefix-length 16 --network agent-relay-vpc --addresses 10.40.0.0
gcloud services vpc-peerings connect --service servicenetworking.googleapis.com \
  --network agent-relay-vpc --ranges agent-relay-psa
gcloud compute routers create agent-relay-router --network agent-relay-vpc --region $R
gcloud compute routers nats create agent-relay-nat --router agent-relay-router --region $R \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
gcloud container clusters create agent-relay --location $R --num-nodes 1 \
  --machine-type e2-standard-4 --disk-type pd-balanced --disk-size 100 \
  --network agent-relay-vpc --subnetwork agent-relay-subnet --enable-ip-alias \
  --cluster-secondary-range-name pods --services-secondary-range-name services \
  --workload-pool=$P.svc.id.goog --workload-metadata=GKE_METADATA \
  --addons HttpLoadBalancing,GcePersistentDiskCsiDriver --release-channel regular \
  --enable-private-nodes --master-ipv4-cidr 172.16.0.0/28 \
  --enable-master-authorized-networks --master-authorized-networks <your IP>/32 \
  --enable-shielded-nodes --enable-dataplane-v2
```

**`Operation denied by org policy ... default Compute Engine service
account`?** Your organization does not allow nodes to run as the default
service account. Create one for the nodes and pass it:

```sh
gcloud iam service-accounts create agent-relay-nodes
gcloud projects add-iam-policy-binding $P --role roles/container.defaultNodeServiceAccount \
  --member "serviceAccount:agent-relay-nodes@$P.iam.gserviceaccount.com"
```

then add `--service-account agent-relay-nodes@$P.iam.gserviceaccount.com` to
the `clusters create` command, and in step 4 set
`gke_node_service_account = "agent-relay-nodes@<project id>.iam.gserviceaccount.com"`
so the image mirror grants it read access.

A regional cluster with `--num-nodes 1` gets one node in each of the region's
three zones. Then continue at step 1 with `<cluster>` = `agent-relay` and
`<cluster VPC>` = `agent-relay-vpc`, and grant the node service account in
step 5. Run everything that needs `kubectl` from an address in the authorized
list.

**Done when:** step 2's checks pass on the new cluster.
