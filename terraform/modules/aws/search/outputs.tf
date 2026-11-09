output "domain_name" {
  description = "Domain name."
  value       = local.domain.domain_name
}

output "domain_arn" {
  description = "Domain ARN."
  value       = local.domain.arn
}

output "endpoint" {
  description = "Private VPC HTTPS endpoint host (no scheme). https://<endpoint> is meant for the sessions pipeline's OpenSearch SearchIndexAdapter (no chart value)."
  value       = local.domain.endpoint
}

output "url" {
  description = "https://<endpoint>."
  value       = "https://${local.domain.endpoint}"
}

output "dashboard_endpoint" {
  description = "OpenSearch Dashboards host inside the VPC."
  value       = local.domain.dashboard_endpoint
}

output "indexer_role_arn" {
  description = "Indexer workload role (Pod Identity). Map it to an OpenSearch role with write permissions on the transcript indices (backend_roles) using the master user."
  value       = try(aws_iam_role.workload["indexer"].arn, null)
}

output "reader_role_arn" {
  description = "Read API workload role (Pod Identity). Map it to an OpenSearch role with read permissions on the transcript indices."
  value       = try(aws_iam_role.workload["reader"].arn, null)
}

output "pod_identity_association_ids" {
  description = "Pod Identity associations created, keyed by role/cluster/namespace/service-account."
  value       = { for k, v in aws_eks_pod_identity_association.workload : k => v.association_id }
}

output "indexer_policy_json" {
  description = "The indexer's IAM policy, to attach to an existing role (EKS Pod Identity allows one role per ServiceAccount, so a pod that already has a role gets this policy on that role)."
  value       = local.policies["indexer"]
}

output "reader_policy_json" {
  description = "The reader's IAM policy, to attach to an existing role."
  value       = local.policies["reader"]
}

output "sessions_read_policy_json" {
  description = "Read-only sessions bucket policy for existing roles (workload_roles.create = false), or null when sessions_bucket_read is unset."
  value       = local.sessions_read_policy
}
