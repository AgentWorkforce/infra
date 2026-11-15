# S3 ledger re-arm sweeper (sessions-pipeline chart rearmSweeper with
# credentials.mode podIdentity; pipeline decision 0005). Operations from the
# chart README "Re-arm sweeper IAM". It is the only role here that may delete
# canonical object versions, so it has its own ServiceAccount, and an explicit
# deny keeps that delete off every dot-prefixed namespace under the key root
# (.upload-inbox, .admission-inbox, .ledger).
locals {
  rearm_sweeper_enabled = local.history_upload_enabled && try(var.history_upload.rearm_sweeper_service_account, null) != null
  rearm_key_root        = local.history_upload_enabled ? "${module.sessions_bucket.bucket_arn}/${var.history_upload.key_root}" : null
}

resource "aws_iam_role" "rearm_sweeper" {
  count                = local.rearm_sweeper_enabled ? 1 : 0
  name                 = "${local.name}-rearm-sweeper"
  path                 = local.role_path
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"] }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "rearm_sweeper" {
  count = local.rearm_sweeper_enabled ? 1 : 0
  name  = "s3-ledger-rearm-sweeper"
  role  = aws_iam_role.rearm_sweeper[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Unconditioned: a prefix condition turns a missing record's HEAD into 403.
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation"], Resource = module.sessions_bucket.bucket_arn },
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${local.rearm_key_root}/.admission-inbox/*/ledger/rearm/*",
          "${local.rearm_key_root}/.admission-inbox/*/ledger/owners/*",
          "${local.rearm_key_root}/.admission-inbox/*/upload-fences.json",
          "${local.rearm_key_root}/.ledger/rearm-sweeper/*",
          "${local.rearm_key_root}/*/v1/ws=*/manifest.json",
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = [
          "${local.rearm_key_root}/.admission-inbox/*/ledger/rearm/*.done/*",
          "${local.rearm_key_root}/.admission-inbox/*/ledger/rearm/*.corrupt/*",
          "${local.rearm_key_root}/.ledger/rearm-sweeper/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:DeleteObjectVersion"]
        Resource = ["${local.rearm_key_root}/*/v1/ws=*", "${local.rearm_key_root}/*/live-sessions/v1/ws=*"]
      },
      # Org ids never start with a dot; the inbox, admission and ledger
      # namespaces do. A version delete there is never the sweeper's.
      { Effect = "Deny", Action = ["s3:DeleteObjectVersion", "s3:DeleteObject"], Resource = "${local.rearm_key_root}/.*" },
      {
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = var.kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "rearm_sweeper" {
  count           = local.rearm_sweeper_enabled ? 1 : 0
  cluster_name    = var.eks_cluster_name
  namespace       = local.namespace
  service_account = var.history_upload.rearm_sweeper_service_account
  role_arn        = aws_iam_role.rearm_sweeper[0].arn
  tags            = local.tags
}
