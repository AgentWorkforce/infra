output "role_arn" {
  description = "The scoped role's ARN: put it in the broker allowlist as the account's roles.scoped."
  value       = aws_iam_role.scoped.arn
}

output "trust_policy" {
  description = "The scoped role's trust policy, for review."
  value       = local.trust_policy
}

output "ceiling_policy" {
  description = "The scoped role's deny ceiling, for review."
  value       = local.ceiling_policy
}
