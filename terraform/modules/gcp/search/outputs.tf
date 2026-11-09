output "url" {
  description = "In-cluster HTTPS endpoint, meant for the sessions pipeline's OpenSearch SearchIndexAdapter (no chart value). Trust the operator-generated CA from the <name>-http-cert Secret (ca.crt)."
  value       = "https://${var.name}.${var.namespace}.svc:9200"
}

output "namespace" {
  description = "Cluster namespace."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "service_name" {
  description = "Cluster Service name."
  value       = var.name
}

output "service_account_name" {
  description = "Kubernetes service account the OpenSearch pods run as (bind it to a Google service account for GCS snapshots)."
  value       = local.service_account
}

output "cluster_release_name" {
  description = "Helm release name of the cluster chart."
  value       = helm_release.cluster.name
}
