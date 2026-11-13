output "role_arn" {
  description = "The worker's role (Pod Identity; the chart needs no annotation)."
  value       = aws_iam_role.worker.arn
}

output "service_account" {
  description = "The ServiceAccount the association binds; the worker chart must run as it."
  value       = var.service_account
}

output "resource_policy_statements" {
  description = "Statements the bucket's owner merges into the bucket policy and the key policy (by Sid). Nothing here writes them: they live in the other account."
  # With S3 Bucket Keys, S3 sends the bucket ARN as the encryption context, so each key grant also
  # accepts it; the S3 statements still limit which objects the worker reads and writes.
  value = {
    bucket_policy = [
      { Sid = "SessionsWorkerLists", Effect = "Allow", Principal = { AWS = aws_iam_role.worker.arn }, Action = "s3:ListBucket", Resource = var.sessions_bucket_arn },
      { Sid = "SessionsWorkerReads", Effect = "Allow", Principal = { AWS = aws_iam_role.worker.arn }, Action = "s3:GetObject", Resource = local.session_objects },
      { Sid = "SessionsWorkerWritesSummaries", Effect = "Allow", Principal = { AWS = aws_iam_role.worker.arn }, Action = "s3:PutObject", Resource = local.summary_objects },
    ]
    key_policy = [
      {
        Sid       = "SessionsWorkerDecryptsViaS3"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.worker.arn }
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com", "kms:CallerAccount" = var.account_id }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = ["arn:aws:s3:::${local.bucket_name}/${var.key_base}/*/v1/*", var.sessions_bucket_arn] }
        }
      },
      {
        Sid       = "SessionsWorkerEncryptsSummariesViaS3"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.worker.arn }
        Action    = "kms:GenerateDataKey"
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com", "kms:CallerAccount" = var.account_id }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = ["arn:aws:s3:::${local.bucket_name}/${var.key_base}/*/v1/*/summary/*", var.sessions_bucket_arn] }
        }
      },
    ]
  }
}
