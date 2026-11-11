output "control_env" {
  description = "Relay Control environment for the private feed, as strings for relay-control.extraEnv. Contains no secret."
  value = {
    SELFHOST_DESKTOP_FEED_SIGNER          = "awskms"
    SELFHOST_DESKTOP_FEED_STORAGE         = "s3"
    SELFHOST_DESKTOP_FEED_KMS_REGION      = local.region
    SELFHOST_DESKTOP_FEED_KMS_KEY_ALIASES = jsonencode({ for p, k in aws_kms_alias.feed : p => k.name })
    SELFHOST_DESKTOP_FEED_S3_BUCKET       = var.create_bucket ? module.bucket[0].bucket_name : var.bucket_name
    SELFHOST_DESKTOP_FEED_S3_REGION       = var.create_bucket ? module.bucket[0].bucket_region : local.region
    SELFHOST_DESKTOP_FEED_S3_PREFIX       = var.prefix
  }
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
