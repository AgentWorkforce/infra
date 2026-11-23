output "role_arn" {
  description = "Must equal broker/allowlist.json accounts.<prod account>.roles.elevated."
  value       = aws_iam_role.read.arn
}

output "role_name" {
  description = "The role's name (the allowlist ARN's last part)."
  value       = aws_iam_role.read.name
}

output "trust_policy" {
  description = "The role's trust policy, for review."
  value       = local.trust_policy
}

output "permissions_policy" {
  description = "The role's only AWS permissions, for review."
  value       = local.permissions_policy
}

output "cluster_arn" {
  description = "The one cluster the session policy and the role's permission name."
  value       = local.cluster_arn
}
