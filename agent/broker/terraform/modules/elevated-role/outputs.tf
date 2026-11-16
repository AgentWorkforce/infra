output "role_arn" {
  description = "Put in the broker allowlist as the account's roles.elevated."
  value       = aws_iam_role.elevated.arn
}

output "trust_policy" {
  description = "The role's trust policy, for review."
  value       = local.trust_policy
}

output "ceiling_by_sid" {
  description = "The ceiling's statements keyed by Sid (for tests and review)."
  value       = { for s in local.ceiling_policy.Statement : s.Sid => s }
}

output "role_name" {
  description = "The role's name (the allowlist ARN's last part)."
  value       = aws_iam_role.elevated.name
}
