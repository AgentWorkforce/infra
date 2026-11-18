# Regulated profile: customer-managed keys and Binary Authorization

Optional settings for installs that must hold their own encryption keys
(CMEK) and control which images may run. Everything here is off by default;
Google encrypts all of it at rest with Google-managed keys either way.

**Recommended for every install:** [encrypt Kubernetes Secrets](#1-kubernetes-secrets)
with your own key. It is the one item you can turn on for a running cluster
with no replacement, and the install's database URLs and signing keys live in
Kubernetes Secrets.

The Terraform inputs are covered by plan tests with a mock provider. None of
this has been applied to a live project from this repository; check each
"Done when".

## What uses which key

Two example files turn everything on:
`terraform/examples/gcp-foundation/regulated.tfvars.example` (cluster) and
`terraform/examples/gcp/regulated.tfvars.example` (data).

| Data | Terraform root | Input | Service agent that needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key | On an existing install |
| --- | --- | --- | --- | --- |
| Kubernetes Secrets (etcd) | `gcp-foundation` | `kms.secrets` | `service-<number>@container-engine-robot.iam.gserviceaccount.com` | Updates in place |
| Node boot disks | `gcp-foundation` | `kms.node_disks` | `service-<number>@compute-system.iam.gserviceaccount.com` | **Replaces the node pools** |
| Memorystore for Redis | `gcp-foundation` `kms.redis`, or `gcp` `pipeline_redis_kms_key_name` | | `service-<number>@cloud-redis.iam.gserviceaccount.com` | **Replaces the instance** |
| Pub/Sub topics | `gcp-foundation` `pipeline.kms_key_name`, or `gcp` `pipeline_pubsub_kms_key_name` | | `service-<number>@gcp-sa-pubsub.iam.gserviceaccount.com` | Updates in place (new messages) |
| Cloud SQL | `gcp` | `kms_key_name` | `service-<number>@gcp-sa-cloud-sql.iam.gserviceaccount.com` | **Replaces the instance**: restore from a backup into a new instance instead |
| Sessions bucket, desktop feed bucket | `gcp` | `kms_key_name` | `service-<number>@gs-project-accounts.iam.gserviceaccount.com` | Updates in place (new objects) |
| Cloud SQL admin password (Secret Manager) | `gcp` | `admin_secret_kms_key_name` | `service-<number>@gcp-sa-secretmanager.iam.gserviceaccount.com` | **Replaces the secret** |
| Image mirror (Artifact Registry) | `gcp` | `image_mirror_kms_key_name` | `service-<number>@gcp-sa-artifactregistry.iam.gserviceaccount.com` | **Replaces the repository** |
| Persistent volumes (Relaycast, search) | none | A StorageClass, see [below](#persistent-volumes) | the Compute Engine agent above | New volumes only |

`<number>` is the project number. Every key must be in the same region as the
resource. The `gcp-foundation` root grants its three agents for you
(`kms.grant_service_agents`, on by default); for the `gcp` root, grant them
before the first apply:

```sh
KEY=projects/<key project>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>
NUMBER=$(gcloud projects describe <project id> --format='value(projectNumber)')
for agent in gcp-sa-cloud-sql gs-project-accounts gcp-sa-pubsub cloud-redis gcp-sa-secretmanager gcp-sa-artifactregistry; do
  gcloud kms keys add-iam-policy-binding "$KEY" \
    --member "serviceAccount:service-$NUMBER@$agent.iam.gserviceaccount.com" \
    --role roles/cloudkms.cryptoKeyEncrypterDecrypter
done
```

A service agent exists only after its API has been used once in the project.
If a binding fails with `does not exist`, create the agent:
`gcloud beta services identity create --service <api>.googleapis.com --project <project id>`.

**If a key is disabled or destroyed, the data it protects is unreadable.**
Keep the key's own access, rotation and deletion protection under change
control.

## 1. Kubernetes Secrets

GKE then encrypts every Secret with your key before it is written to etcd.

In the `gcp-foundation` root's tfvars:

```hcl
kms = { secrets = "projects/<key project>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>" }
```

Run `terraform plan` (it shows the cluster updated in place and one KMS
binding added) and apply.

**Cluster not made by this Terraform?**

```sh
gcloud kms keys add-iam-policy-binding "$KEY" --role roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --member "serviceAccount:service-$NUMBER@container-engine-robot.iam.gserviceaccount.com"
gcloud container clusters update <cluster> --location <region> --database-encryption-key "$KEY"
```

**Done when:**

```sh
gcloud container clusters describe <cluster> --location <region> --format='value(databaseEncryption.state,databaseEncryption.keyName)'
```

prints `ENCRYPTED` and the key. Secrets written before the change are
re-encrypted the next time they are written. To do it now:

```sh
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

## 2. Data services

Add `regulated.tfvars` (from the example) to the data root at step 4 of
[0-START-HERE.md](0-START-HERE.md), before the first apply:

```sh
terraform plan -var-file=terraform.tfvars -var-file=regulated.tfvars -out tfplan
```

**Done when:**

```sh
gcloud sql instances describe $CLOUD_SQL_INSTANCE --format='value(diskEncryptionConfiguration.kmsKeyName)'
gcloud storage buckets describe gs://$SESSIONS_BUCKET --format='value(default_kms_key)'
gcloud redis instances describe agent-relay-pipeline --region $REGION --format='value(customerManagedKey)'
gcloud pubsub topics list --format='table(name,kmsKeyName)'
```

Each prints the key.

**An existing install.** The table's last column says what a key does to a
resource that already exists. Read the plan: `must be replaced` on Cloud SQL,
Redis or the admin secret means Terraform would delete the data. Leave those
inputs out and plan a migration instead (for Cloud SQL: create a new
CMEK instance and restore a backup into it, as in
[selfhost-backup-restore.md](../selfhost-backup-restore.md)). The bucket and
Pub/Sub inputs are safe to add; objects written before the change keep their
old encryption until they are rewritten.

### Persistent volumes

Relaycast (SQLite backend) and the optional search cluster keep data on
persistent disks. Create a StorageClass with your key and name it in the
values (`relaycast.persistence.storageClass`; `search_storage_class` in the
data root):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: agent-relay-cmek
provisioner: pd.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: pd-balanced
  disk-encryption-kms-key: projects/<key project>/locations/<region>/keyRings/<ring>/cryptoKeys/<key>
```

Only new volumes use it. An existing volume keeps its encryption.

## 3. Binary Authorization

With it on, GKE admits a pod only if every image in it passes the project's
Binary Authorization policy. The install's images are pinned by digest and
copied to your Artifact Registry mirror in step 5, so the policy below allows
exactly that mirror and nothing else.

1. **Check the images before you mirror them.** The release images are built
   with provenance. For those with a GitHub attestation
   ([self-hosted-image-supply-chain.md](../self-hosted-image-supply-chain.md)
   says which), verify the digest came from the AgentWorkforce build:

   ```sh
   gh attestation verify oci://ghcr.io/agentworkforce/relay-control@sha256:<digest> --owner AgentWorkforce
   ```

   Step 5 then copies by digest, so what runs is what you verified.

2. **Write the policy**, first in dry-run so nothing is blocked:

   ```sh
   cat > binauthz-policy.yaml <<'EOF'
   globalPolicyEvaluationMode: ENABLE
   defaultAdmissionRule:
     evaluationMode: ALWAYS_DENY
     enforcementMode: DRYRUN_AUDIT_LOG_ONLY
   admissionWhitelistPatterns:
     - namePattern: <region>-docker.pkg.dev/<project id>/agent-relay-mirror/**
   EOF
   gcloud services enable binaryauthorization.googleapis.com
   gcloud container binauthz policy import binauthz-policy.yaml
   ```

   `globalPolicyEvaluationMode: ENABLE` admits Google's own GKE system
   images. Anything else the cluster runs (the search operator, External
   Secrets Operator, cert-manager) must come from the mirror too, or have its
   own `namePattern`.

3. **Turn enforcement on in the cluster.** In the `gcp-foundation` tfvars:

   ```hcl
   binary_authorization_enforce = true
   ```

   or, for a cluster not made by this Terraform:

   ```sh
   gcloud container clusters update <cluster> --location <region> \
     --binauthz-evaluation-mode PROJECT_SINGLETON_POLICY_ENFORCE
   ```

4. **Look for images the policy would have blocked.** Restart the workloads
   (`kubectl -n $NAMESPACE rollout restart deployment`), wait for them, then:

   ```sh
   gcloud logging read 'logName:"cloudaudit.googleapis.com%2Fsystem_event" AND labels."imagepolicywebhook.image-policy.k8s.io/dry-run"="true"' \
     --freshness 1d --format='value(labels."imagepolicywebhook.image-policy.k8s.io/overridden-verification-result")'
   ```

5. **Enforce.** When that prints nothing, change `enforcementMode` to
   `ENFORCED_BLOCK_AND_AUDIT_LOG` and import the policy again.

**Done when:** a pod from an image outside the mirror is refused, and the
install's pods still start:

```sh
kubectl run binauthz-test --image=docker.io/library/busybox:1.36 --restart=Never -- true
```

prints `denied by Binary Authorization default admission rule`.

- **Upgrades.** Mirror the new release's images (step 5) before
  `helm upgrade`. An image that is not in the mirror is refused, and its pod
  stays in `FailedCreate`.
- **Break glass.** A pod annotated
  `alpha.image-policy.k8s.io/break-glass: "true"` is admitted and logged.
  Restrict who can create pods in the namespace accordingly.
- **Signed attestations instead of an allowlist.** For a policy that requires
  an attestation per digest, create an attestor with a Cloud KMS key and sign
  each digest after step 1; see Google's
  [attestation guide](https://cloud.google.com/binary-authorization/docs/creating-attestations-kms).
  This repository does not automate it.
