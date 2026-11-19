output "plan_role_arn" {
  description = "Role the plan job assumes (trusted for workflow on branch)."
  value       = aws_iam_role.github["plan"].arn
}

output "apply_role_arn" {
  description = "Role the apply job assumes (trusted for workflow on branch in apply_environment)."
  value       = aws_iam_role.github["apply"].arn
}

output "ci" {
  description = "Non-secret settings for the caller's ci.json."
  value = {
    aws_region           = local.region
    account_id           = local.account
    plan_role_arn        = aws_iam_role.github["plan"].arn
    apply_role_arn       = aws_iam_role.github["apply"].arn
    approval_environment = var.apply_environment
    tfvars_parameter     = var.tfvars_parameter_name
    plan_store           = { bucket = var.state.bucket, prefix = var.plan_store_prefix, kms_key_arn = var.state.kms_key_arn }
  }
}

output "policies" {
  description = "Policy documents by name (read, plan, apply-*), for review and tests."
  value       = { for k, v in local.policies : k => jsonencode(v.document) }
}
