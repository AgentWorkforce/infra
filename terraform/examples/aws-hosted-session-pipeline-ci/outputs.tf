output "plan_role_arn" {
  description = "PLAN_ROLE_ARN for the hosted-session-pipeline-plan environment."
  value       = aws_iam_role.ci["plan"].arn
}

output "apply_role_arn" {
  description = "APPLY_ROLE_ARN for the hosted-session-pipeline environment."
  value       = aws_iam_role.ci["apply"].arn
}

output "github_environment_variables" {
  description = "Shared variables for both GitHub environments (set them there; never commit them)."
  value = {
    AWS_REGION        = var.region
    STATE_BUCKET      = aws_s3_bucket.state.bucket
    STATE_KEY         = var.state_key
    STATE_KMS_KEY_ARN = aws_kms_key.state.arn
    TFVARS_PARAMETER  = aws_ssm_parameter.tfvars.name
  }
}
