locals {
  bucket_arn  = aws_s3_bucket.this.arn
  create_role = var.access_role != null

  object_arns = local.create_role ? (
    length(var.access_role.prefixes) == 0 ? ["${local.bucket_arn}/*"] : [for p in var.access_role.prefixes : "${local.bucket_arn}/${trimsuffix(p, "*")}*"]
  ) : []

  oidc_host = local.create_role && try(var.access_role.oidc_provider_arn, null) != null ? element(split("oidc-provider/", var.access_role.oidc_provider_arn), 1) : null
}

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV2_AWS_62:Notifications belong to their consumer (aws/functions manages its own); this module never owns them.
  #checkov:skip=CKV_AWS_144:Cross-region replication needs a second region and bucket; add it outside the module if required.
  bucket              = var.bucket_name
  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock_enabled
  tags                = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  lifecycle {
    precondition {
      condition     = var.versioning_enabled || !var.object_lock_enabled
      error_message = "Object Lock requires versioning; versioning_enabled cannot be false with object_lock_enabled."
    }
  }
  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  #checkov:skip=CKV_AWS_300:The abort-incomplete-multipart-uploads rule applies to the whole bucket (empty filter).
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  dynamic "rule" {
    for_each = var.versioning_enabled && var.noncurrent_version_expiration_days > 0 ? [1] : []
    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"
      filter {}
      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }
  }

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = "Enabled"
      filter {
        prefix = rule.value.prefix
      }
      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [rule.value.expiration_days]
        content {
          days = expiration.value
        }
      }
      dynamic "transition" {
        for_each = rule.value.transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_logging" "this" {
  count = var.access_log_bucket == null ? 0 : 1

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_log_bucket
  target_prefix = coalesce(var.access_log_prefix, "${var.bucket_name}/")
}

locals {
  tls_deny_statements = [
    {
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    },
    {
      Sid       = "DenyTLSBelow12"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
    },
  ]
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.tls_deny_statements, var.additional_policy_statements)
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# Optional workload role (EKS Pod Identity and/or IRSA)
# ---------------------------------------------------------------------------

locals {
  # Each group is its own conditional list, so no conditional has to unify
  # differently shaped statement objects.
  trust_statements = concat(
    local.create_role ? [{
      Sid       = "EksPodIdentity"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }] : [],
    local.create_role && local.oidc_host != null && length(try(var.access_role.irsa_service_accounts, [])) > 0 ? [{
      Sid       = "Irsa"
      Effect    = "Allow"
      Principal = { Federated = var.access_role.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = [for sa in var.access_role.irsa_service_accounts : "system:serviceaccount:${sa.namespace}:${sa.service_account}"]
        }
      }
    }] : [],
  )

  access_statements = concat(
    local.create_role ? [{
      # Unconditional on purpose: S3 answers 404 (not 403) for a missing key
      # only with ListBucket, and the sessions services detect deletes that way.
      Sid      = "ListBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [local.bucket_arn]
    }] : [],
    local.create_role ? [{
      Sid      = "ReadWriteObjects"
      Effect   = "Allow"
      Action   = concat(["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], var.access_role.allow_delete ? ["s3:DeleteObject"] : [])
      Resource = local.object_arns
    }] : [],
    local.create_role && var.kms_key_arn != null ? [{
      Sid       = "UseBucketKey"
      Effect    = "Allow"
      Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource  = [var.kms_key_arn]
      Condition = { StringEquals = { "kms:ViaService" = "s3.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}" } }
    }] : [],
  )
}

resource "aws_iam_role" "access" {
  count = local.create_role ? 1 : 0

  name                 = var.access_role.name
  path                 = var.access_role.path
  assume_role_policy   = jsonencode({ Version = "2012-10-17", Statement = local.trust_statements })
  permissions_boundary = var.access_role.permissions_boundary_arn
  tags                 = var.tags
}

data "aws_region" "current" {}
data "aws_partition" "current" {}

resource "aws_iam_role_policy" "access" {
  count = local.create_role ? 1 : 0

  name   = "s3-${var.bucket_name}"
  role   = aws_iam_role.access[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.access_statements })
}

resource "aws_eks_pod_identity_association" "access" {
  for_each = local.create_role ? { for a in var.access_role.pod_identity_associations : "${a.cluster_name}/${a.namespace}/${a.service_account}" => a } : {}

  cluster_name    = each.value.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.access[0].arn
  tags            = var.tags
}
