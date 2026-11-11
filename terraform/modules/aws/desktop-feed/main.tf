data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  bucket_arn  = "arn:${local.partition}:s3:::${var.bucket_name}"
  create_role = var.role.create
  aliases     = { for p in var.profiles : p => "alias/${var.name}-${p}" }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SignFeedManifests"
        Effect   = "Allow"
        Action   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
        Resource = [for k in aws_kms_key.feed : k.arn]
      },
      {
        # Unconditional, as in modules/aws/object-storage: S3 answers 404 rather
        # than 403 for a missing key only when the caller may list the bucket.
        Sid      = "ListFeedBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "ReadWriteFeedObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = ["${local.bucket_arn}/${var.prefix}/*"]
      },
    ]
  })
}

# One asymmetric key per profile: each profile's Desktop builds embed that key's
# public half, so keys are never shared or rotated in place.
resource "aws_kms_key" "feed" {
  #checkov:skip=CKV_AWS_7:Automatic rotation is not supported for asymmetric keys; a new profile key means new Desktop builds.
  for_each = var.profiles

  description              = "${var.name} Desktop feed signing key for profile ${each.key}"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_EDWARDS25519"
  deletion_window_in_days  = var.key_deletion_window_days
  # The account default: IAM policies (the policy below) grant use.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministrationThroughIam"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
  tags = var.tags
}

resource "aws_kms_alias" "feed" {
  for_each = var.profiles

  name          = local.aliases[each.key]
  target_key_id = aws_kms_key.feed[each.key].key_id
}

# Control writes every object with SSE-S3 (AES256) explicitly; the bucket's
# default SSE-KMS (aws/s3) only applies to writes without that header.
module "bucket" {
  source = "../object-storage"
  count  = var.create_bucket ? 1 : 0

  bucket_name       = var.bucket_name
  force_destroy     = var.force_destroy
  access_log_bucket = var.access_log_bucket
  tags              = var.tags
}

resource "aws_iam_role" "control" {
  count = local.create_role ? 1 : 0

  name                 = coalesce(var.role.name, var.name)
  path                 = var.role.path
  permissions_boundary = var.role.permissions_boundary_arn
  tags                 = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EksPodIdentity"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "control" {
  count = local.create_role ? 1 : 0

  name   = "desktop-feed-${var.name}"
  role   = aws_iam_role.control[0].id
  policy = local.policy
}

resource "aws_eks_pod_identity_association" "control" {
  for_each = local.create_role ? { for a in var.role.pod_identity_associations : "${a.cluster_name}/${a.namespace}/${a.service_account}" => a } : {}

  cluster_name    = each.value.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.control[0].arn
  tags            = var.tags
}
