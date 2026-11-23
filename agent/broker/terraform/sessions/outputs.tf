output "role_arn" {
  description = "Must equal broker/allowlist.json accounts.<sessions account>.roles.elevated."
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

output "function_arn" {
  description = "The one function the role may read the configuration of. A request's resources name this ARN."
  value       = local.function_arn
}

output "log_group_arn" {
  description = "The one log group the role may read. A request's resources name this ARN and the same ARN with :* (its streams)."
  value       = local.log_group_arn
}
