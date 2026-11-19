output "bootstrap_role_arn" {
  description = "Set as sandbox_assume_role_arn in ../sandbox terraform.tfvars, and as assume_role.role_arn in its backend.hcl."
  value       = aws_iam_role.bootstrap.arn
}

output "state_bucket" {
  description = "Set as bucket in ../sandbox backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "trust_policy" {
  description = "The bootstrap role's trust policy, for review."
  value       = local.trust_policy
}

output "permissions_policy" {
  description = "The bootstrap role's only permissions, for review."
  value       = local.permissions_policy
}

output "bucket_policy" {
  description = "The state bucket's policy, for review."
  value       = local.bucket_policy
}
