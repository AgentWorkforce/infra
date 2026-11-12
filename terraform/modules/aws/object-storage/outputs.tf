output "bucket_name" {
  description = "Bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider s3, endpoint \"\"), or durable-actors storage.bucket and the relaycast/relayfile artifactBucket in values-eks-actors.yaml."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "Bucket ARN (for IAM policies and the functions module's S3 notification)."
  value       = aws_s3_bucket.this.arn
}

output "bucket_region" {
  description = "Bucket region. Feeds worker.locker.region / alleyoop.locker.region (or durable-actors storage.s3.region)."
  value       = aws_s3_bucket.this.region
}

output "access_role_arn" {
  description = "Workload role ARN (null when access_role is unset). With Pod Identity no chart value is needed (the association binds it; keep locker.credentials.mode podIdentity); with IRSA annotate the ServiceAccount with eks.amazonaws.com/role-arn."
  value       = try(aws_iam_role.access[0].arn, null)
}

output "access_role_name" {
  description = "Workload role name (null when access_role is unset)."
  value       = try(aws_iam_role.access[0].name, null)
}

output "pod_identity_association_ids" {
  description = "Pod Identity associations created, keyed by cluster/namespace/service-account."
  value       = { for k, v in aws_eks_pod_identity_association.access : k => v.association_id }
}

output "history_upload_role_arn" {
  description = "Write-only upload role for Control's SELFHOST_HISTORY_UPLOAD_ROLE_ARN (null when disabled)."
  value       = try(aws_iam_role.history_upload[0].arn, null)
}

output "bucket_policy_statements" {
  description = "Every statement this module puts in the bucket policy (TLS denies, history_upload's inbox wall, additional_policy_statements), also when unmanaged includes \"policy\" and the policy is not applied. Merge them by hand into an unmanaged policy."
  value       = concat(local.tls_deny_statements, local.upload_bucket_denies, var.additional_policy_statements)
}

output "upload_wall_statements" {
  description = "history_upload's bucket-policy denies (the upload inbox wall), empty without history_upload. A caller with unmanaged \"policy\" must confirm the live policy contains them."
  value       = local.upload_bucket_denies
}
