output "control_env" {
  description = "Relay Control's SELFHOST_DESKTOP_FEED_* settings as a name-to-value map. Contains no secret; use control_extra_env for relay-control.extraEnv."
  value       = local.control_env
}

output "control_extra_env" {
  description = "control_env as the [{name, value}] list relay-control.extraEnv expects, sorted by name."
  value       = [for k in sort(keys(local.control_env)) : { name = k, value = local.control_env[k] }]
}

output "key_aliases" {
  description = "Profile ID to KMS alias."
  value       = { for p, k in aws_kms_alias.feed : p => k.name }
}

output "key_arns" {
  description = "Profile ID to KMS key ARN."
  value       = { for p, k in aws_kms_key.feed : p => k.arn }
}

output "bucket_arn" {
  description = "Feed bucket ARN."
  value       = local.bucket_arn
}

output "policy_json" {
  description = "The Control feed permissions; attach it to an existing Control role when role.create = false."
  value       = local.policy
}

output "role_arn" {
  description = "Control workload role ARN (null when role.create = false)."
  value       = try(aws_iam_role.control[0].arn, null)
}

output "pod_identity_association_ids" {
  description = "Pod Identity associations created, keyed by cluster/namespace/service-account."
  value       = { for k, v in aws_eks_pod_identity_association.control : k => v.association_id }
}
