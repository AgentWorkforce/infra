# One Pod Identity role per Control ServiceAccount. Reuse the desktop-feed
# role when it exists; never create a competing association for that account.
locals {
  history_upload_enabled = var.history_upload != null
  history_control_role_arn = local.history_upload_enabled ? (
    var.desktop_feed != null ? module.desktop_feed[0].role_arn : aws_iam_role.history_control[0].arn
  ) : null
}

resource "aws_iam_role" "history_control" {
  count                = local.history_upload_enabled && var.desktop_feed == null ? 1 : 0
  name                 = "${local.name}-history-control"
  path                 = local.role_path
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"] }]
  })
  tags = local.tags
}

resource "aws_eks_pod_identity_association" "history_control" {
  count           = local.history_upload_enabled && var.desktop_feed == null ? 1 : 0
  cluster_name    = var.eks_cluster_name
  namespace       = local.namespace
  service_account = var.history_upload.control_service_account
  role_arn        = aws_iam_role.history_control[0].arn
  tags            = local.tags
}

# The native ingest-edge process owns both the HTTP status/control routes and
# the upload-inbox scan. Its role is distinct from readers and legacy workers.
resource "aws_iam_role" "history_consumer" {
  count                = local.history_upload_enabled ? 1 : 0
  name                 = "${local.name}-history-consumer"
  path                 = local.role_path
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"] }]
  })
  tags = local.tags
  lifecycle {
    # The unmanaged-policy wall check compares against this predicted ARN.
    postcondition {
      condition     = !local.unmanaged_policy || self.arn == local.history_consumer_role_arn
      error_message = "The history consumer role ARN differs from the one the unmanaged bucket policy's inbox wall names."
    }
    precondition {
      condition     = var.desktop_feed == null ? true : var.desktop_feed.service_account == var.history_upload.control_service_account
      error_message = "Desktop feed and history uploads must share the same Control ServiceAccount and Pod Identity role."
    }
    precondition {
      condition     = var.pipeline_runtime == "workers" && var.kms_key_arn != null
      error_message = "Self-host history uploads require native worker scanning and a customer-managed KMS key. Lambda upload admission is configured separately."
    }
    precondition {
      condition     = !contains([for sa in ["worker", "alleyoop", "session-ingest-api"] : "${var.release_name}-${sa}"], var.history_upload.consumer_service_account)
      error_message = "Consumer must use a dedicated ServiceAccount, separate from existing legacy storage associations."
    }
  }
}

resource "aws_iam_role_policy" "history_consumer" {
  count = local.history_upload_enabled ? 1 : 0
  name  = "history-native-consumer"
  role  = aws_iam_role.history_consumer[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = module.sessions_bucket.bucket_arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${module.sessions_bucket.bucket_arn}/${var.history_upload.key_root}/*" },
      {
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = var.kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "history_consumer" {
  count           = local.history_upload_enabled ? 1 : 0
  cluster_name    = var.eks_cluster_name
  namespace       = local.namespace
  service_account = var.history_upload.consumer_service_account
  role_arn        = aws_iam_role.history_consumer[0].arn
  tags            = local.tags
}
