output "role_arn" {
  description = "The broker role's ARN: the only principal the target roles trust."
  value       = aws_iam_role.broker.arn
}

output "trust_policy" {
  description = "The broker role's trust policy, for review."
  value       = local.trust_policy
}

output "permissions_policy" {
  description = "The broker role's only permissions, for review."
  value       = local.permissions_policy
}
