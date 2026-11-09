# gcp/search

**Optional.** OpenSearch on your existing **GKE** cluster through the [OpenSearch Kubernetes operator](https://github.com/opensearch-project/opensearch-k8s-operator), as the transcript search index. It replaces ClickHouse; the default stays Postgres `pg_trgm`. It is meant for the sessions pipeline's OpenSearch `SearchIndexAdapter` (sessions-pipeline-cloud); the charts set no value for it.

## Why OpenSearch on GKE (and not Elastic Cloud)

Google Cloud has no managed OpenSearch. The options were:

| Option | For | Against |
|---|---|---|
| **OpenSearch on GKE (operator)**, chosen | Same engine, API and clients as Amazon OpenSearch Service, so the one future sessions-pipeline OpenSearch backend serves both clouds. Runs inside the customer's cluster and VPC: no third-party contract, no peering, no data leaving the project. Apache 2.0. | The customer operates it: upgrades, capacity, snapshots and node sizing. Needs persistent disks and a `vm.max_map_count` raise (a privileged init container, or a node system config on Autopilot). |
| Elastic Cloud (GCP Marketplace) | Fully managed, Private Service Connect available, billed through GCP. | Elasticsearch, not OpenSearch: the APIs and clients have diverged since 7.10, so the services would need a second search backend. Also a separate vendor account, the `elastic/ec` provider with an API key, and a PSC endpoint the customer must create. |
| Aiven for OpenSearch (Marketplace) | Managed OpenSearch. | Private access needs VPC peering into Aiven's VPC, which this module set never creates. Another vendor contract. |

This module installs the operator and an `OpenSearchCluster`. If a customer
prefers Elastic Cloud, they provision it themselves and give the services its
endpoint once an Elasticsearch-compatible backend exists.

## What it creates

- The operator (Helm, optional with `install_operator = false`) and an `opensearch-cluster` release in a dedicated namespace.
- 3 nodes (cluster_manager, data, ingest) with 200Gi each by default, on `storage_class`.
- TLS on HTTP and transport with operator-generated certificates. The CA is in the `<name>-http-cert` Secret (`ca.crt`).
- Security from **existing** Secrets only: `admin_credentials_secret_name` (username and password) and `security_config_secret_name` (the security plugin files, including the indexer and reader users or roles). Create both with External Secrets Operator from Secret Manager. The module never generates a password, so none is in state.
- ClusterIP only, with no Ingress and Dashboards off. There is a NetworkPolicy admitting only the namespace itself, the operator namespace and `network_policy.allowed_namespaces` (for example `agent-relay`).
- Snapshots: create a bucket with `gcp/object-storage` and a Google service account for the `service_account_name` output. Set `service_account_annotations` and `plugins = ["repository-gcs"]`, then register the repository.

Configure the `helm` and `kubernetes` providers in the root module against the cluster (see `examples/gcp`).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| helm | >= 2.17, < 4.0 |
| kubernetes | >= 2.30, < 4.0 |

### Providers

| Name | Version |
| ---- | ------- |
| helm | >= 2.17, < 4.0 |
| kubernetes | >= 2.30, < 4.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [helm_release.cluster](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_network_policy_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/network_policy_v1) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_credentials\_secret\_name | Existing Secret in namespace with username and password for the admin user (create it with External Secrets Operator from Secret Manager). The password never enters Terraform state. | `string` | n/a | yes |
| security\_config\_secret\_name | Existing Secret in namespace with the security plugin files (config.yml, internal\_users.yml with the admin hash, roles.yml, roles\_mapping.yml, ...). It defines the indexer and reader users or roles. | `string` | n/a | yes |
| additional\_values | Extra opensearch-cluster chart values (YAML), merged after the module's. | `list(string)` | `[]` | no |
| chart\_repository | Helm repository for the operator and cluster charts (mirror it for air-gapped installs). | `string` | `"https://opensearch-project.github.io/opensearch-k8s-operator/"` | no |
| cluster\_chart\_version | opensearch-cluster chart version. | `string` | `"3.3.5"` | no |
| dashboards\_enabled | Deploy OpenSearch Dashboards (ClusterIP only). | `bool` | `false` | no |
| disk\_size | Persistent volume per node. Size for the transcript text plus replicas plus ~25% headroom. | `string` | `"200Gi"` | no |
| image | OpenSearch image repository (mirror it to Artifact Registry for private clusters). | `string` | `"docker.io/opensearchproject/opensearch"` | no |
| install\_operator | Install the OpenSearch Kubernetes operator. Turn off when the cluster already runs one. | `bool` | `true` | no |
| labels | Labels for the namespace. | `map(string)` | `{}` | no |
| name | OpenSearch cluster name (also its Service name: https://<name>.<namespace>.svc:9200). | `string` | `"relay-search"` | no |
| namespace | Namespace for the cluster (created by the module). | `string` | `"opensearch"` | no |
| network\_policy | Create a NetworkPolicy for the namespace that admits traffic only from itself, the operator namespace and allowed\_namespaces (needs NetworkPolicy enforcement: GKE Dataplane V2 or Calico). | ```object({ enabled = optional(bool, true) allowed_namespaces = optional(list(string), []) })``` | `{}` | no |
| node\_selector | Node selector for OpenSearch pods (for example a dedicated node pool). | `map(string)` | `{}` | no |
| opensearch\_version | OpenSearch version. 2.19 matches the AWS module's default engine (one client and index mapping for both clouds). | `string` | `"2.19.3"` | no |
| operator\_chart\_version | opensearch-operator chart version. | `string` | `"3.0.14"` | no |
| operator\_namespace | Namespace for the operator. | `string` | `"opensearch-operator-system"` | no |
| plugins | Extra plugins to install (for example repository-gcs for snapshots to a GCS bucket). | `list(string)` | `[]` | no |
| replicas | Nodes (cluster\_manager + data). Three tolerate one node loss. | `number` | `3` | no |
| resources | Requests and limits per node. The JVM heap is half the memory limit by default. | ```object({ requests = map(string) limits = map(string) })``` | ```{ "limits": { "cpu": "4", "memory": "8Gi" }, "requests": { "cpu": "2", "memory": "8Gi" } }``` | no |
| service\_account\_annotations | Annotations for the cluster's Kubernetes service account, for example iam.gke.io/gcp-service-account=<email> for GCS snapshots through Workload Identity. | `map(string)` | `{}` | no |
| set\_vm\_max\_map\_count | Let the operator raise vm.max\_map\_count with a privileged init container. GKE Autopilot refuses privileged containers: set false there and use a node system config or a node pool with the setting. | `bool` | `true` | no |
| storage\_class | StorageClass for the node volumes (an encrypted, ideally CMEK, pd-ssd/hyperdisk class). null uses the cluster default. | `string` | `null` | no |
| tolerations | Tolerations for OpenSearch pods. | `list(any)` | `[]` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_release\_name | Helm release name of the cluster chart. |
| namespace | Cluster namespace. |
| service\_account\_name | Kubernetes service account the OpenSearch pods run as (bind it to a Google service account for GCS snapshots). |
| service\_name | Cluster Service name. |
| url | In-cluster HTTPS endpoint, meant for the sessions pipeline's OpenSearch SearchIndexAdapter (no chart value). Trust the operator-generated CA from the <name>-http-cert Secret (ca.crt). |
<!-- END_TF_DOCS -->
