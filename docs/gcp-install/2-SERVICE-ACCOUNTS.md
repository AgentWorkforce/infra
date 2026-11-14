# Agent Relay on GKE: service accounts and Workload Identity

What the Agent Relay install needs from IAM, so you can create it with your
own tooling. `create-workload-identity.sh` here is an **optional** way to do it
with `gcloud`. The Terraform in step 4 of 0-START-HERE.md creates all of this
for you; read this page only if you create resources yourself
(1-BRING-YOUR-OWN.md) or want to review the grants.

The pods get Google Cloud access through **GKE Workload Identity Federation**,
granted **directly to the Kubernetes ServiceAccounts**. There are no Google
service accounts to create, no service account keys and no HMAC keys. Every
grant is on one resource (the bucket, the topic, the subscription), never on
the project.

The namespace and ServiceAccount names below are fixed: the Helm chart creates
exactly these. The examples use namespace `agent-relay`; if you change it,
change it everywhere.

## Cluster prerequisites

- Workload Identity is **enabled on the cluster**
  (`workloadPool: <project id>.svc.id.goog`), and every node pool that runs
  Agent Relay uses the GKE metadata server (`workloadMetadataConfig: GKE_METADATA`).
- The **node service account** can pull from your Artifact Registry mirror
  (`roles/artifactregistry.reader` on that repository). With
  `image_mirror_repository` set, step 4's Terraform creates the repository and
  this grant (for the default Compute Engine service account, or
  `gke_node_service_account`).

Check:

```sh
gcloud container clusters describe <cluster> --location <region> --format='value(workloadIdentityConfig.workloadPool)'
gcloud container node-pools list --cluster <cluster> --location <region> --format='table(name,config.workloadMetadataConfig.mode)'
```

**Done when:** the first prints `<project id>.svc.id.goog`, and every pool shows
`GKE_METADATA`.

## Principals

Each Kubernetes ServiceAccount is addressed as:

```
principal://iam.googleapis.com/projects/<project NUMBER>/locations/global/workloadIdentityPools/<project id>.svc.id.goog/subject/ns/agent-relay/sa/<ServiceAccount>
```

Use the project **number** in the first part and the project **id** in the pool
name.

## Grants (all resource-level)

| Resource | Role | ServiceAccounts (namespace `agent-relay`) |
|---|---|---|
| Sessions bucket `<bucket>` | `roles/storage.objectUser` | `agent-relay-worker`, `agent-relay-session-ingest-api`, `agent-relay-read-api`, `agent-relay-search-indexer`, `agent-relay-alleyoop` |
| Pub/Sub topic `<name>-pipeline` | `roles/pubsub.publisher` | `agent-relay-worker`, `agent-relay-session-ingest-api` |
| Pub/Sub subscription `<name>-pipeline` | `roles/pubsub.subscriber` | `agent-relay-worker`, `agent-relay-search-indexer` |
| Pub/Sub topic `<name>-pipeline-dead-letter` | `roles/pubsub.publisher` | the Pub/Sub service agent `service-<project number>@gcp-sa-pubsub.iam.gserviceaccount.com` |
| Pub/Sub subscription `<name>-pipeline` | `roles/pubsub.subscriber` | the same Pub/Sub service agent (needed for dead-lettering) |
| Artifact Registry repository (your mirror; Terraform-made with `image_mirror_repository`) | `roles/artifactregistry.reader` | the GKE node service account |
| Secret Manager secret holding the Cloud SQL admin password | `roles/secretmanager.secretAccessor` | **the person running the install** (not a pod) |

`agent-relay-alleyoop` isn't used by this install: its Deployment is off. The
grant is harmless and matches the tested setup.

Nothing in the cluster needs a Cloud SQL IAM role: the services connect to the
private IP with database passwords over verified TLS (`sslmode=verify-full`).
Memorystore has no IAM grant either: the pinned services connect with TLS and
without Redis AUTH, so restrict Memorystore reachability to the cluster's VPC.

**With a customer-managed KMS key (CMEK)** on the bucket, Cloud SQL or the
Pub/Sub topics: grant `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key
to the **service agents** of Cloud Storage
(`service-<project number>@gs-project-accounts.iam.gserviceaccount.com`), Cloud
SQL (`service-<project number>@gcp-sa-cloud-sql.iam.gserviceaccount.com`) and
Pub/Sub (`service-<project number>@gcp-sa-pubsub.iam.gserviceaccount.com`)
before creating those resources. The pods themselves need no KMS role.

## Who runs the install

The person running 0-START-HERE.md needs, in the project:

- to create the resources (step 4): Cloud SQL Admin, Storage Admin,
  Pub/Sub Admin, Cloud Memorystore Redis Admin, DNS Administrator (for the
  private Cloud SQL zone), Secret Manager Admin, Compute Network Viewer, and
  permission to set IAM policy on the resources above; or the project Owner
  or Editor role;
- `roles/container.developer` (or admin) on the cluster, plus Kubernetes RBAC
  to create a namespace and cluster-scoped objects;
- `roles/secretmanager.secretAccessor` on the Cloud SQL admin password secret
  (`cloud-sql-setup.sh` reads it).

## What we need back

Nothing. The pods pick up their access through Workload Identity; the chart
only needs the namespace and names to match.
