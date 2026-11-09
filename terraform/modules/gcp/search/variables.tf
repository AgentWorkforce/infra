variable "name" {
  description = "OpenSearch cluster name (also its Service name: https://<name>.<namespace>.svc:9200)."
  type        = string
  default     = "relay-search"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,39}[a-z0-9])?$", var.name))
    error_message = "name must be 1-41 lowercase letters, digits and hyphens, starting with a letter and ending with a letter or digit (it is a Service name)."
  }
}

variable "namespace" {
  description = "Namespace for the cluster (created by the module)."
  type        = string
  default     = "opensearch"
}

variable "install_operator" {
  description = "Install the OpenSearch Kubernetes operator. Turn off when the cluster already runs one."
  type        = bool
  default     = true
}

variable "operator_namespace" {
  description = "Namespace for the operator."
  type        = string
  default     = "opensearch-operator-system"
}

variable "chart_repository" {
  description = "Helm repository for the operator and cluster charts (mirror it for air-gapped installs)."
  type        = string
  default     = "https://opensearch-project.github.io/opensearch-k8s-operator/"
}

variable "operator_chart_version" {
  description = "opensearch-operator chart version."
  type        = string
  default     = "3.0.14"
}

variable "cluster_chart_version" {
  description = "opensearch-cluster chart version."
  type        = string
  default     = "3.3.5"
}

variable "opensearch_version" {
  description = "OpenSearch version. 2.19 matches the AWS module's default engine (one client and index mapping for both clouds)."
  type        = string
  default     = "2.19.3"
}

variable "image" {
  description = "OpenSearch image repository (mirror it to Artifact Registry for private clusters)."
  type        = string
  default     = "docker.io/opensearchproject/opensearch"
}

variable "replicas" {
  description = "Nodes (cluster_manager + data). Three tolerate one node loss."
  type        = number
  default     = 3

  validation {
    condition     = var.replicas >= 1 && floor(var.replicas) == var.replicas
    error_message = "replicas must be a whole number of at least 1."
  }
}

variable "disk_size" {
  description = "Persistent volume per node. Size for the transcript text plus replicas plus ~25% headroom."
  type        = string
  default     = "200Gi"
}

variable "storage_class" {
  description = "StorageClass for the node volumes (an encrypted, ideally CMEK, pd-ssd/hyperdisk class). null uses the cluster default."
  type        = string
  default     = null
}

variable "resources" {
  description = "Requests and limits per node. The JVM heap is half the memory limit by default."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "2", memory = "8Gi" }
    limits   = { cpu = "4", memory = "8Gi" }
  }
}

variable "node_selector" {
  description = "Node selector for OpenSearch pods (for example a dedicated node pool)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for OpenSearch pods."
  type        = list(any)
  default     = []
}

variable "set_vm_max_map_count" {
  description = "Let the operator raise vm.max_map_count with a privileged init container. GKE Autopilot refuses privileged containers: set false there and use a node system config or a node pool with the setting."
  type        = bool
  default     = true
}

variable "admin_credentials_secret_name" {
  description = "Existing Secret in namespace with username and password for the admin user (create it with External Secrets Operator from Secret Manager). The password never enters Terraform state."
  type        = string

  validation {
    condition     = length(var.admin_credentials_secret_name) > 0
    error_message = "admin_credentials_secret_name is required: the module never generates an admin password."
  }
}

variable "security_config_secret_name" {
  description = "Existing Secret in namespace with the security plugin files (config.yml, internal_users.yml with the admin hash, roles.yml, roles_mapping.yml, ...). It defines the indexer and reader users or roles."
  type        = string

  validation {
    condition     = length(var.security_config_secret_name) > 0
    error_message = "security_config_secret_name is required: the demo security configuration is never used."
  }
}

variable "plugins" {
  description = "Extra plugins to install (for example repository-gcs for snapshots to a GCS bucket)."
  type        = list(string)
  default     = []
}

variable "service_account_annotations" {
  description = "Annotations for the cluster's Kubernetes service account, for example iam.gke.io/gcp-service-account=<email> for GCS snapshots through Workload Identity."
  type        = map(string)
  default     = {}
}

variable "dashboards_enabled" {
  description = "Deploy OpenSearch Dashboards (ClusterIP only)."
  type        = bool
  default     = false
}

variable "network_policy" {
  description = "Create a NetworkPolicy for the namespace that admits traffic only from itself, the operator namespace and allowed_namespaces (needs NetworkPolicy enforcement: GKE Dataplane V2 or Calico)."
  type = object({
    enabled            = optional(bool, true)
    allowed_namespaces = optional(list(string), [])
  })
  default = {}
}

variable "additional_values" {
  description = "Extra opensearch-cluster chart values (YAML), merged after the module's."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels for the namespace."
  type        = map(string)
  default     = {}
}
