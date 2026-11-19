# S3 Express One Zone state for durable-actors, with a regional S3 Standard checkpoint.
#
# Express directory buckets do not evaluate s3:* object actions: a principal calls
# s3express:CreateSession on the bucket and the session authorizes object operations. So every
# Express grant here is CreateSession on exactly one bucket ARN. Per-actor narrowing happens in
# the STS session policy that the control plane attaches when it assumes the actor role (see
# AgentWorkforce/durable-actors docs/s3-express-checkpoint.md); IAM cannot narrow CreateSession
# to a key prefix.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_role" "control_plane" {
  name = var.control_plane_role_name
}

# The role applying this module. The directory bucket policy must admit it, or the next plan
# cannot read the bucket (HeadBucket on a directory bucket needs a session) and drops it from state.
data "aws_iam_session_context" "operator" {
  arn = data.aws_caller_identity.current.arn
}

# Fails the plan when the zone ID does not exist in this region.
data "aws_availability_zone" "express" {
  zone_id = var.express_az_id
}

locals {
  express_bucket = "${var.name}--${var.express_az_id}--x-s3"
  express_arn    = "arn:${data.aws_partition.current.partition}:s3express:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:bucket/${local.express_bucket}"
  checkpoint_arn = module.checkpoint.bucket_arn
  prefix         = var.storage_prefix
  kms_statements = var.kms_key_arn == null ? [] : [{
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
    Resource = var.kms_key_arn
  }]
}

resource "aws_s3_directory_bucket" "express" {
  bucket          = local.express_bucket
  data_redundancy = "SingleAvailabilityZone"
  type            = "Directory"
  force_destroy   = false

  location {
    name = var.express_az_id
    type = "AvailabilityZone"
  }

  lifecycle {
    precondition {
      condition     = contains(var.express_supported_az_ids, var.express_az_id)
      error_message = "express_az_id ${var.express_az_id} (${data.aws_availability_zone.express.name}) has no S3 Express One Zone; choose one of express_supported_az_ids."
    }
    precondition {
      condition     = length(local.express_bucket) <= 63
      error_message = "The directory bucket name ${local.express_bucket} exceeds 63 characters; shorten name."
    }
  }
}

# Only the control plane, the actor role (through per-actor STS sessions), the role applying this
# module and named operators may open sessions on the Express bucket, whatever other identity
# policies in the account allow.
resource "aws_s3_bucket_policy" "express" {
  bucket = aws_s3_directory_bucket.express.bucket
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyDurableActorsSessions"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3express:CreateSession"
      Resource  = local.express_arn
      Condition = {
        ArnNotLike = {
          "aws:PrincipalArn" = concat(
            [data.aws_iam_role.control_plane.arn, aws_iam_role.actor.arn, data.aws_iam_session_context.operator.issuer_arn],
            var.express_operator_principal_arns,
          )
        }
      }
    }]
  })
}

module "checkpoint" {
  source = "../object-storage"

  bucket_name                        = var.checkpoint_bucket_name
  kms_key_arn                        = var.kms_key_arn
  versioning_enabled                 = true
  noncurrent_version_expiration_days = var.checkpoint_noncurrent_version_expiration_days
  tags                               = var.tags
}

# Assumed only by the control plane, which narrows each session to one actor with an inline
# session policy. Hosts never receive this role's unscoped credentials.
resource "aws_iam_role" "actor" {
  name                 = "${var.name}-actor-storage"
  max_session_duration = 3600
  permissions_boundary = var.actor_role_permissions_boundary_arn
  tags                 = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_iam_role.control_plane.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# The ceiling for any actor session: Express sessions on one bucket, the actor-owned prefixes of
# the checkpoint copy (owner records, snapshots) and read-only artifacts. Snapshots are create-only.
resource "aws_iam_role_policy" "actor" {
  name = "durable-actors-express-actor"
  role = aws_iam_role.actor.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ExpressSessions"
        Effect   = "Allow"
        Action   = "s3express:CreateSession"
        Resource = local.express_arn
      },
      {
        Sid      = "CheckpointOwners"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${local.checkpoint_arn}/${local.prefix}owners/*"
      },
      {
        Sid       = "CheckpointSnapshotsCreateOnly"
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = "${local.checkpoint_arn}/${local.prefix}snapshots/*"
        Condition = { StringEquals = { "s3:if-none-match" = "*" } }
      },
      {
        Sid      = "CheckpointReads"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = ["${local.checkpoint_arn}/${local.prefix}snapshots/*", "${local.checkpoint_arn}/${local.prefix}artifacts/*"]
      },
      {
        Sid       = "CheckpointList"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.checkpoint_arn
        Condition = { StringLike = { "s3:prefix" = ["${local.prefix}owners/*", "${local.prefix}snapshots/*", "${local.prefix}artifacts/*"] } }
      },
    ], local.kms_statements)
  })
}

resource "aws_iam_role_policy" "control_plane" {
  name = "durable-actors-express-control-plane"
  role = var.control_plane_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ExpressSessions"
        Effect   = "Allow"
        Action   = "s3express:CreateSession"
        Resource = local.express_arn
      },
      {
        Sid      = "Checkpoint"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${local.checkpoint_arn}/${local.prefix}*"
      },
      {
        Sid       = "CheckpointList"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.checkpoint_arn
        Condition = { StringLike = { "s3:prefix" = "${local.prefix}*" } }
      },
      {
        Sid      = "ActorSessions"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = aws_iam_role.actor.arn
      },
    ], local.kms_statements)
  })
}

# Deployers upload compiled bundles to the regional bucket with If-None-Match: * and read them
# back; they never touch Express, so their plain SigV4 uploads keep working.
resource "aws_iam_role_policy" "deployer" {
  for_each = toset(var.deployer_role_names)
  name     = "durable-actors-express-deployer"
  role     = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "ArtifactsCreateOnly"
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = "${local.checkpoint_arn}/${local.prefix}artifacts/*"
        Condition = { StringEquals = { "s3:if-none-match" = "*" } }
      },
      {
        Sid      = "ArtifactsRead"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.checkpoint_arn}/${local.prefix}artifacts/*"
      },
    ], local.kms_statements)
  })
}
