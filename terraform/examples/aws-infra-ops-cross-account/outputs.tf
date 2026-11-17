output "role_arn" {
  description = "The operator role. Assume it from the trusted role: aws sts assume-role --role-arn <this> --role-session-name <who>."
  value       = aws_iam_role.operator.arn
}

output "role_name" {
  description = "The operator role's name."
  value       = aws_iam_role.operator.name
}

output "aws_config_profile" {
  description = "A profile for the operator's AWS config (its default profile is the trusted role); carries the external id when one is set."
  value = join("", concat([
    "[profile ${var.account_id}]\n",
    "role_arn = ${aws_iam_role.operator.arn}\n",
    "source_profile = default\n",
    "region = ${var.region}\n",
  ], var.external_id == null ? [] : ["external_id = ${var.external_id}\n"]))
}
