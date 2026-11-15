# The sessions-pipeline worker (summary worker and status worker) in this EKS
# cluster, reading a sessions bucket owned by another account. Same grant as the
# pipeline's own worker role (relayhistory-pipeline stacks/aws/hardening.ts
# workerPolicy): list the bucket, read session objects, write encrypted
# summaries, use the bucket key through S3 only. Cross-account access needs the
# bucket owner's side too: output.resource_policy_statements.
locals {
  bucket_name     = trimprefix(var.sessions_bucket_arn, "arn:aws:s3:::")
  kms_region      = split(":", var.sessions_kms_key_arn)[3]
  session_objects = "${var.sessions_bucket_arn}/${var.key_base}/*/v1/*"
  summary_objects = "${var.sessions_bucket_arn}/${var.key_base}/*/v1/*/summary/*"
  # IAM * spans /, so session_objects also matches the upload inbox (unverified desktop uploads). The
  # bucket's inbox wall denies it in the other account; this Deny keeps that true from this side too.
  upload_inbox = "${var.sessions_bucket_arn}/${var.key_base}/.upload-inbox/*"
}

resource "aws_iam_role" "worker" {
  name                 = var.role_name
  path                 = var.role_path
  permissions_boundary = var.permissions_boundary_arn
  # EKS Pod Identity tags the session with the cluster (ARN, so a same-named
  # cluster in another Region does not match), namespace and
  # ServiceAccount (the shape the cluster's EBS CSI role uses); only this
  # release's worker may assume the role.
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

resource "aws_iam_role_policy" "worker" {
  name = "sessions-worker"
  role = aws_iam_role.worker.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Unconditioned: S3 answers 404 (not 403) for a missing key only with ListBucket.
      { Sid = "ListForMissingKeySemantics", Effect = "Allow", Action = ["s3:ListBucket"], Resource = var.sessions_bucket_arn },
      { Sid = "ReadSessionObjects", Effect = "Allow", Action = ["s3:GetObject"], Resource = local.session_objects },
      { Sid = "WriteEncryptedSummaries", Effect = "Allow", Action = ["s3:PutObject"], Resource = local.summary_objects },
      { Sid = "NoUploadInbox", Effect = "Deny", Action = ["s3:*"], Resource = local.upload_inbox },
      {
        Sid       = "SessionsKeyViaS3"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = var.sessions_kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "s3.${local.kms_region}.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "worker" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.worker.arn
  tags            = var.tags
}
