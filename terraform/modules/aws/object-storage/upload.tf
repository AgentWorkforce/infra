data "aws_caller_identity" "upload" {}

# relay-upload-inbox-v1. Control assumes a write-only role with a narrower
# per-user inline session policy. Desktop never receives Control credentials.
locals {
  upload_enabled  = var.history_upload != null
  upload_objects  = local.upload_enabled ? "${local.bucket_arn}/${var.history_upload.key_root}/.upload-inbox/*" : ""
  upload_journals = local.upload_enabled ? "${local.bucket_arn}/${var.history_upload.key_root}/.admission-inbox/*/v1/ws=*/m=srv_*/privacy-journal.json" : ""
  upload_bucket_denies = concat(local.upload_enabled ? [
    {
      Sid       = "UploadInboxConsumerOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:GetObjectVersion", "s3:DeleteObject", "s3:DeleteObjectVersion"]
      Resource  = local.upload_objects
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = var.history_upload.consumer_role_arns } }
    },
    ] : [], local.upload_enabled ? [{
      Sid       = "UploadInboxCreateOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:PutObject"
      Resource  = local.upload_objects
      Condition = { Null = { "s3:if-none-match" = "true" } }
    },
  ] : [])
}

resource "aws_iam_role" "history_upload" {
  count                = local.upload_enabled ? 1 : 0
  name                 = var.history_upload.name
  path                 = var.history_upload.path
  permissions_boundary = var.history_upload.permissions_boundary_arn
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ControlWithUserSourceIdentity"
        Effect    = "Allow"
        Principal = { AWS = var.history_upload.control_role_arn }
        Action    = ["sts:AssumeRole", "sts:SetSourceIdentity"]
        Condition = { StringLike = { "sts:SourceIdentity" = "u_*" } }
      },
      {
        # A Pod Identity session carries transitive session tags into the chained AssumeRole. Under the
        # SourceIdentity condition above, TagSession is denied and Control answers 503
        # upload_credentials_unavailable. TagSession alone never grants the role.
        Sid       = "ControlTransitiveSessionTags"
        Effect    = "Allow"
        Principal = { AWS = var.history_upload.control_role_arn }
        Action    = "sts:TagSession"
      },
    ]
  })
  tags = var.tags
  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws(-[a-z]+)*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$", var.kms_key_arn))
      error_message = "history_upload requires a customer-managed KMS key; the aws/s3 key cannot authorize the upload role."
    }
    precondition {
      condition     = startswith(var.history_upload.control_role_arn, "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.upload.account_id}:role/")
      error_message = "The issuer policy can only attach to a Control role in this AWS account and partition."
    }
  }
}

resource "aws_iam_role_policy" "history_upload" {
  count = local.upload_enabled ? 1 : 0
  name  = "upload-inbox-only"
  role  = aws_iam_role.history_upload[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CreateUploadObjects"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = local.upload_objects
        Condition = {
          StringEquals = {
            "s3:x-amz-server-side-encryption"                = "aws:kms"
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = var.kms_key_arn
          }
          Null = { "s3:if-none-match" = "false" }
        }
      },
      {
        Sid      = "UploadDataKey"
        Effect   = "Allow"
        Action   = "kms:GenerateDataKey"
        Resource = var.kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}" }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = local.upload_objects }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "history_upload_issuer" {
  count = local.upload_enabled ? 1 : 0
  name  = "${var.history_upload.name}-issuer"
  role  = element(reverse(split("/", var.history_upload.control_role_arn)), 0)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "MintUploadSessions"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"]
        Resource = aws_iam_role.history_upload[0].arn
      },
      {
        Sid      = "ReadPrivacyJournal"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = local.upload_journals
      },
      {
        # Without ListBucket a missing journal returns 403, not 404. Control
        # must distinguish an empty journal from a storage/auth failure.
        Sid      = "FindPrivacyJournal"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.bucket_arn
      },
      {
        Sid      = "DecryptPrivacyJournal"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}" }
          # Existing journals may use the bucket-key encryption context.
          StringLike = { "kms:EncryptionContext:aws:s3:arn" = [local.upload_journals, local.bucket_arn] }
        }
      },
    ]
  })
}
