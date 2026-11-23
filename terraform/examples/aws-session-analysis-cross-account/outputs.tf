output "role_arn" {
  description = "Dedicated session-analysis Pod Identity role ARN."
  value       = aws_iam_role.runner.arn
}

output "service_account" {
  description = "ServiceAccount the Pod Identity association binds."
  value       = var.service_account
}

output "resource_policy_statements" {
  description = "Exact statements for the bucket owner to merge into the bucket and KMS key policies. The bucket stack must separately carve this role out of its result-delete Deny."
  value = {
    bucket_policy = [
      { Sid = "SessionAnalysisLists", Effect = "Allow", Principal = { AWS = aws_iam_role.runner.arn }, Action = "s3:ListBucket", Resource = var.sessions_bucket_arn },
      { Sid = "SessionAnalysisReads", Effect = "Allow", Principal = { AWS = aws_iam_role.runner.arn }, Action = "s3:GetObject", Resource = local.session_objects },
      { Sid = "SessionAnalysisWritesResults", Effect = "Allow", Principal = { AWS = aws_iam_role.runner.arn }, Action = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.analysis_results },
      {
        Sid       = "SessionAnalysisListsResultVersions"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.runner.arn }
        Action    = "s3:ListBucketVersions"
        Resource  = var.sessions_bucket_arn
        Condition = { StringLike = { "s3:prefix" = local.result_prefix } }
      },
    ]
    key_policy = [
      {
        Sid       = "SessionAnalysisDecryptsViaS3"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.runner.arn }
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com", "kms:CallerAccount" = var.account_id }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "arn:aws:s3:::${local.bucket_name}/${var.key_base}/*/v1/*" }
        }
      },
      {
        Sid       = "SessionAnalysisEncryptsViaS3"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.runner.arn }
        Action    = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com", "kms:CallerAccount" = var.account_id }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "arn:aws:s3:::${local.bucket_name}/${var.key_base}/*/v1/*/normalized/session-analysis-v2/*" }
        }
      },
    ]
  }
}
