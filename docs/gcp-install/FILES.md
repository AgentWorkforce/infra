# GCP operator reference files

Customer-neutral install guide for **agent-relay-2026.11.19** on an existing GKE
cluster, the GCP counterpart of the AWS EKS guide. For customer setup start with [the short guide](README.md).
For operator commands use [0-START-HERE.md](0-START-HERE.md).

For a customer-managed corporate VPN connector, see the optional
[VPN network profile](../vpn-networking.md). Review its NAT and ingress-address
ownership notes before running the numbered guide; the connector is distinct
from the foundation's Serverless VPC Access connector.

| File | What it is |
|---|---|
| `0-START-HERE.md` | Numbered copy-paste steps, each with a "Done when" check |
| `1-BRING-YOUR-OWN.md` | Specs for creating Cloud SQL, GCS, Memorystore, Pub/Sub, search and certificates yourself instead of Terraform |
| `2-SERVICE-ACCOUNTS.md` | Workload Identity: every grant the install needs, and who needs which roles |
| `3-EDGE-HARDENING.md` | Optional: the load balancer's TLS policy, Cloud Armor, and Cloudflare in front |
| `EDGE-DESKTOP-CONFIG.md` | Optional: prepare consistent edge, Desktop and signed-feed configuration |
| `NOT-QUALIFIED.md` | What 2026.11.19 does not yet qualify on GKE. Read before a production rollout |
| `REGULATED-PROFILE.md` | Optional: customer-managed encryption keys (Kubernetes Secrets, Cloud SQL, bucket, Pub/Sub, Redis, disks) and Binary Authorization |
| `images.md` | The release images and how they are mirrored |
| `values.yaml` | Site values template (placeholders filled in step 9) |
| `external-secrets-values.yaml` | Optional overlay: the install Secrets from Google Secret Manager through External Secrets Operator (step 10 d) |
| `cloud-sql-setup.sh` | Database and role setup in Jobs inside the cluster (steps 8 and 13) |
| `helm-secrets-prepare.sh` | Secrets for helm-secrets with SOPS, or vals with Google Secret Manager (step 10) |
| `create-workload-identity.sh` | Optional: the Workload Identity grants with gcloud |
| `managed-values-byo.sh` | Bring-your-own: builds `managed-values.json` from your resources |
| `add-user.sh` | Add users with temporary passwords, without SMTP (step 15) |
| `workspace-ids.sh` | List workspace IDs and names, for titles and summaries (step 16) |

`cloud-sql-setup.sh` is the repository's `scripts/selfhost/cloud-sql-setup.sh`
including the fix in AgentWorkforce/infra#276. Keep the two in sync.
