output "role_arn" {
  description = "The operator role. Assume it from the trusted role: aws sts assume-role --role-arn <this> --role-session-name <who>."
  value       = aws_iam_role.operator.arn
}

output "role_name" {
  description = "The operator role's name."
  value       = aws_iam_role.operator.name
}

output "aws_config_profile" {
  description = "A ~/.aws/config profile for the operator (its default profile is the trusted role)."
  value       = <<-EOT
    [profile ${var.account_id}]
    role_arn = ${aws_iam_role.operator.arn}
    source_profile = default
    region = ${var.region}
  EOT
}
