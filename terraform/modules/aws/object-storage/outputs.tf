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
