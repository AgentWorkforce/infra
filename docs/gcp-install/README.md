# Agent Relay on Google Cloud (GKE): install guide

Customer-neutral install guide for **agent-relay-2026.11.1** on an existing GKE
cluster, the GCP counterpart of the AWS EKS guide. Start with
**0-START-HERE.md**.

| File | What it is |
|---|---|
| `0-START-HERE.md` | Numbered copy-paste steps, each with a "Done when" check |
| `1-BRING-YOUR-OWN.md` | Specs for creating Cloud SQL, GCS, Memorystore, Pub/Sub, search and certificates yourself instead of Terraform |
| `2-SERVICE-ACCOUNTS.md` | Workload Identity: every grant the install needs, and who needs which roles |
| `NOT-QUALIFIED.md` | What 2026.11.1 does not yet qualify on GKE. Read before a production rollout |
| `images.md` | The release images and how they are mirrored |
| `values.yaml` | Site values template (placeholders filled in step 9) |
| `cloud-sql-setup.sh` | Database and role setup in Jobs inside the cluster (steps 8 and 13) |
| `helm-secrets-prepare.sh` | Secrets for helm-secrets with SOPS, or vals with Google Secret Manager (step 10) |
| `create-workload-identity.sh` | Optional: the Workload Identity grants with gcloud |
| `managed-values-byo.sh` | Bring-your-own: builds `managed-values.json` from your resources |
| `add-user.sh` | Add users with temporary passwords, without SMTP (step 15) |

`cloud-sql-setup.sh` is the repository's `scripts/selfhost/cloud-sql-setup.sh`
including the fix in AgentWorkforce/infra#276. Keep the two in sync.
