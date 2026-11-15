# Bringing your own Google Cloud resources (instead of Terraform)

Use this page instead of step 4 of 0-START-HERE.md if your team creates every
resource itself. Create the items below, all in the **same project and region
as the GKE cluster**, on the **cluster's VPC**, then continue at step 5.

**Workload Identity grants on their own:** see 2-SERVICE-ACCOUNTS.md (what's
needed, plus an optional `gcloud` script that creates it).

Names in `<...>` are yours. The namespace (`agent-relay`) and the
ServiceAccount names are fixed: the Helm chart creates exactly these.

## 0. Network

The cluster's VPC needs **Private Services Access** (an allocated range and a
`servicenetworking.googleapis.com` peering). Cloud SQL and Memorystore both
take private addresses from it. Nothing in this install uses a public IP except
the load balancer.

## 1. Cloud SQL for PostgreSQL

| Setting | Value |
|---|---|
| Version | PostgreSQL **17** |
| Edition / size (proof of concept) | Enterprise, `db-custom-2-7680` (2 vCPU, 7.5 GB), 100 GB SSD with storage auto-increase |
| Availability | **Regional** (high availability) |
| Connectivity | **Private IP only** on the cluster VPC (Private Services Access); public IP **off** |
| Server CA mode | **`GOOGLE_MANAGED_CAS_CA`** (shared CA). Required: the services verify the server with `sslmode=verify-full` against the instance's DNS name |
| SSL mode | `ENCRYPTED_ONLY` (no client certificates) |
| Backups | automated daily, 14 retained, point-in-time recovery on (7 days of logs) |
| Flags | `cloudsql.iam_authentication=on` (unused by the services but harmless), `log_connections`, `log_disconnections`, `log_checkpoints`, `log_lock_waits` = `on` |
| Extensions | `vector`, `pg_trgm`, `btree_gin` (created by `cloud-sql-setup.sh`) |
| Databases | none needed up front: `cloud-sql-setup.sh pre` creates `relaycontrol`, `relaycast` and `hoopdb` |

An admin login for the install, with its password in Secret Manager. Don't use
the `postgres` user; this login's password is read by `cloud-sql-setup.sh`:

```sh
read -rs -p 'Password for agent_relay_admin: ' PW; echo
gcloud sql users create agent_relay_admin --instance <instance> --password "$PW"   # or set it in the console
printf '%s' "$PW" | gcloud secrets create agent-relay-pg-admin-password --data-file=- --replication-policy automatic
unset PW
```

(`gcloud sql users create --password` puts the password on the command line of
your own shell. If that is not acceptable, set it in the console.)

**The private DNS name.** With the shared CA, the server certificate names the
instance's DNS name, e.g. `<id>.<hash>.<region>.sql-psa.goog.`. The cluster
must resolve that name to the private IP:

```sh
gcloud sql instances describe <instance> --format='value(dnsNames[0].name,ipAddresses[0].ipAddress)'
gcloud dns managed-zones create <instance>-cloud-sql --visibility private \
  --networks <cluster VPC> --dns-name <that DNS name> --description 'Cloud SQL verified DNS'
gcloud dns record-sets create <that DNS name> --zone <instance>-cloud-sql --type A --ttl 300 --rrdatas <private IP>
```

**Done when:** from inside the cluster,
`kubectl run pgcheck --rm -i --restart=Never --image=<MIRROR_ROOT>/ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3 -- pg_isready -h <that DNS name> -p 5432 -t 10`
prints `accepting connections`.

## 2. GCS bucket for session data

| Setting | Value |
|---|---|
| Location | the cluster's region |
| Storage class | Standard |
| Access control | **uniform bucket-level access**; public access prevention **enforced** |
| Versioning | **on**, with a lifecycle rule deleting noncurrent versions after 30 days |
| Soft delete | 7 days (the GCS default) |
| Lifecycle | abort incomplete multipart uploads after 7 days |
| Encryption | Google-managed, or CMEK (grant the Cloud Storage service agent on the key first) |

## 3. Memorystore for Redis

| Setting | Value |
|---|---|
| Tier | **Standard** (HA), 5 GB |
| Version | Redis 7.2 |
| Network | the cluster VPC, connect mode **Private Services Access** |
| In-transit encryption | **Server authentication** (TLS) |
| AUTH | **off**. The pinned services don't send Redis credentials. Reachability is the control: keep the instance on a VPC that only the cluster (and your admins) can reach |
| Maintenance | any weekly window (the tested one is Sunday 04:00 UTC) |

## 4. Pub/Sub

- Topic `<name>-pipeline`, message retention 7 days, storage restricted to the
  cluster's region.
- Topic `<name>-pipeline-dead-letter`, same settings.
- Pull subscription `<name>-pipeline` on the first topic: ack deadline
  600 s, retention 7 days, never expires, retry backoff 10 s to 600 s,
  dead-letter to `<name>-pipeline-dead-letter` after 8 attempts.
- Pull subscription `<name>-pipeline-dead-letter` on the dead-letter topic,
  retention 7 days, never expires (for inspecting failures).

## 5. Search

Nothing to create. Transcript search is stored in Cloud SQL (the chart's
`postgres` search backend). This release doesn't support OpenSearch on GKE
(see NOT-QUALIFIED.md).

## 6. HTTPS certificate

Nothing to create. The chart creates a **Google-managed certificate**
(`ManagedCertificate`) for `<domain>`, `api.<domain>`, `cast.<domain>` and
`history.<domain>` on the GKE Ingress. You reserve the global static IP and
create the four DNS A records (step 6 of 0-START-HERE.md); Google issues the
certificate once those resolve.

**Your own certificate instead** (from your CA): create a Kubernetes TLS
Secret for all four names, or a Certificate Manager / pre-shared SSL
certificate, and tell us. The tested path is the Google-managed certificate.

## 7. Workload Identity grants

Create the grants in 2-SERVICE-ACCOUNTS.md, with your own tooling or with:

```sh
PROJECT_ID=<project id> BUCKET=<bucket> TOPIC=<name>-pipeline SUBSCRIPTION=<name>-pipeline \
DEAD_LETTER_TOPIC=<name>-pipeline-dead-letter bash create-workload-identity.sh
```

**Done when:** it ends with `done: 11 grants`.

## Then: managed-values.json and the settings file

Generate the non-secret managed-services overlay that Terraform would have
written:

```sh
GCP_PROJECT_ID=<project id> REGION=<region> CLOUD_SQL_INSTANCE=<instance> \
SESSIONS_BUCKET=<bucket> REDIS_INSTANCE=<memorystore instance> \
PUBSUB_TOPIC=<name>-pipeline PUBSUB_SUBSCRIPTION=<name>-pipeline \
  bash managed-values-byo.sh > managed-values.json
```

**Done when:** `jq -r '.["sessions-pipeline"].worker.postgresCa.sha256' managed-values.json`
prints a 64-character hash.

In step 7 of 0-START-HERE.md, replace the six lines between `PG=` and `unset`
in `settings.sh` with:

```sh
export CLOUD_SQL_INSTANCE=<instance>
export CLOUD_SQL_HOST=<the instance DNS name, with its trailing dot>
export CLOUD_SQL_ADMIN_USER=agent_relay_admin
export CLOUD_SQL_ADMIN_SECRET_ID=agent-relay-pg-admin-password
export CLOUD_SQL_CA_SHA256="$(jq -r '.["sessions-pipeline"].worker.postgresCa.sha256' "$INSTALL_DIR/managed-values.json")"
export SESSIONS_BUCKET=<bucket>
```

Then continue with step 5 (images) and steps 6–15 as written.
