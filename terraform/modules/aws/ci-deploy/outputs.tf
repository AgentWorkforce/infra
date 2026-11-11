output "bucket_name" {
  description = "Artifact bucket: plan-bundles/, apply-bundles/, runs/<run>/<mode>/ reports, snapshots/."
  value       = module.artifacts.bucket_name
}

output "plan_project" {
  description = "CodeBuild project the plan role starts."
  value       = aws_codebuild_project.this["plan"].name
}

output "apply_project" {
  description = "CodeBuild project the apply role starts (apply and rollback)."
  value       = aws_codebuild_project.this["apply"].name
}

output "plan_role_arn" {
  description = "Role GitHub assumes for plan (trusted for plan_subjects)."
  value       = aws_iam_role.trigger["plan"].arn
}

output "apply_role_arn" {
  description = "Role GitHub assumes for apply and rollback (trusted only for apply_environment)."
  value       = aws_iam_role.trigger["apply"].arn
}

output "log_group" {
  description = "CloudWatch log group of both projects (streams plan/<build> and apply/<build>)."
  value       = aws_cloudwatch_log_group.builds.name
}

output "plan_rbac_manifest" {
  description = "Role and RoleBinding letting the plan job read Helm release state (Secrets) in var.namespaces. kubectl apply -f once; the apply job re-applies it."
  value       = local.plan_rbac_manifest
}
