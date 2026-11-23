# Dedicated EKS session-analysis runner in one account, reading canonical
# sessions and writing versioned analysis results to a bucket in another.
# The bucket owner must install the matching resource-policy statements from
# output.resource_policy_statements; an Allow cannot override its eraser-only
# explicit Deny, so that stack must also carve out this exact role for the
# result prefix.
locals {
  bucket_name       = trimprefix(var.sessions_bucket_arn, "arn:aws:s3:::")
  kms_region        = split(":", var.sessions_kms_key_arn)[3]
  session_objects   = "${var.sessions_bucket_arn}/${var.key_base}/*/v1/*"
  analysis_results  = "${var.sessions_bucket_arn}/${var.key_base}/*/v1/*/normalized/session-analysis-v2/*"
  result_prefix     = "${var.key_base}/*/v1/*/normalized/session-analysis-v2/*"
  upload_inbox      = "${var.sessions_bucket_arn}/${var.key_base}/.upload-inbox/*"
  admission_inbox   = "${var.sessions_bucket_arn}/${var.key_base}/.admission-inbox/*"
  admission_context = "arn:aws:s3:::${local.bucket_name}/${var.key_base}/.admission-inbox/*"
}

resource "aws_iam_role" "runner" {
  name                 = var.role_name
  path                 = var.role_path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = "arn:aws:eks:${var.region}:${var.account_id}:cluster/${var.eks_cluster_name}"
          "aws:RequestTag/eks-cluster-name"           = var.eks_cluster_name
          "aws:RequestTag/kubernetes-namespace"       = var.namespace
          "aws:RequestTag/kubernetes-service-account" = var.service_account
        }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "runner" {
  name = "session-analysis"
  role = aws_iam_role.runner.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "InspectCanonicalBucket", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketVersioning"], Resource = var.sessions_bucket_arn },
      { Sid = "ReadCanonicalSessions", Effect = "Allow", Action = ["s3:GetObject"], Resource = local.session_objects },
      { Sid = "WriteAnalysisResults", Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = local.analysis_results },
      {
        Sid      = "ListAnalysisResultVersions"
        Effect   = "Allow"
        Action   = ["s3:ListBucketVersions"]
        Resource = var.sessions_bucket_arn
        Condition = { StringLike = {
          "s3:prefix" = local.result_prefix
        } }
      },
      { Sid = "NoUploadInbox", Effect = "Deny", Action = ["s3:*"], Resource = local.upload_inbox },
      { Sid = "NoAdmissionInbox", Effect = "Deny", Action = ["s3:*"], Resource = local.admission_inbox },
      {
        Sid      = "NoAdmissionJournalDecrypt"
        Effect   = "Deny"
        Action   = ["kms:Decrypt"]
        Resource = var.sessions_kms_key_arn
        Condition = {
          StringLike = { "kms:EncryptionContext:aws:s3:arn" = local.admission_context }
        }
      },
      {
        Sid      = "DecryptCanonicalSessionsViaS3"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.sessions_kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com" }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "arn:aws:s3:::${local.bucket_name}/${var.key_base}/*/v1/*" }
        }
      },
      {
        Sid      = "EncryptAnalysisResultsViaS3"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = var.sessions_kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com" }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "arn:aws:s3:::${local.bucket_name}/${var.key_base}/*/v1/*/normalized/session-analysis-v2/*" }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "runner" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.runner.arn
  tags            = var.tags
}
