# Prerequisites in the sandbox account (805532413586) for the broker's
# ../sandbox root, applied once by a human admin there (SSO), never by an agent:
#
#  - layered-infra-ops-broker-tf: a role that only layered-infra-ops' admin
#    role (exact ARN, via aws:PrincipalArn) may assume. It may manage exactly
#    one IAM role, agent-broker-sandbox-scoped (create, update, tag, inline
#    policies, the PowerUserAccess attachment and nothing else, delete) and
#    read and write the broker's state under one key prefix. Nothing else in
#    the account.
#  - agent-cred-broker-tfstate-<account>: the state bucket. Versioned, SSE,
#    every public access block on, ACLs disabled, TLS-only, and only this
#    account's principals.
#
# The ../sandbox root then uses the role for its sandbox provider
# (sandbox_assume_role_arn) and for its S3 backend (assume_role in
# backend.hcl).

provider "aws" {
  region              = var.region
  profile             = var.profile
  allowed_account_ids = [var.sandbox_account_id]
}

locals {
  bootstrap_role_name = "layered-infra-ops-broker-tf"
  bucket_name         = "agent-cred-broker-tfstate-${var.sandbox_account_id}"
  bucket_arn          = "arn:aws:s3:::${local.bucket_name}"
  scoped_role_arn     = "arn:aws:iam::${var.sandbox_account_id}:role/${var.scoped_role_name}"
  power_user_arn      = "arn:aws:iam::aws:policy/PowerUserAccess"

  trust_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid       = "InfraOpsAdminOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${split(":", var.infra_ops_admin_role_arn)[4]}:root" }
      Action    = "sts:AssumeRole"
      Condition = { ArnEquals = { "aws:PrincipalArn" = var.infra_ops_admin_role_arn } }
    }]
  }

  permissions_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # Everything Terraform does to aws_iam_role, aws_iam_role_policy and
        # aws_iam_role_policy_attachment, on the scoped role only.
        Sid    = "ManageTheScopedRoleOnly"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:GetRole", "iam:UpdateRole", "iam:DeleteRole",
          "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
          "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
        ]
        Resource = local.scoped_role_arn
      },
      {
        # The only managed policy it may attach or detach, on the scoped role only.
        Sid       = "AttachPowerUserOnlyToTheScopedRole"
        Effect    = "Allow"
        Action    = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource  = local.scoped_role_arn
        Condition = { ArnEquals = { "iam:PolicyARN" = local.power_user_arn } }
      },
      {
        # No managed policy but PowerUserAccess, on any role: denied even if a later grant is broader.
        Sid      = "NeverAnyOtherManagedPolicy"
        Effect   = "Deny"
        Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource = "*"
        Condition = {
          ArnNotEquals = { "iam:PolicyARN" = local.power_user_arn }
        }
      },
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.bucket_arn
        Condition = {
          StringEquals = { "s3:prefix" = [var.sandbox_state_key, "${var.sandbox_state_key}.tflock"] }
        }
      },
      {
        # Exactly ../sandbox's state and its use_lockfile lock. Never this
        # root's own state (bootstrap.tfstate): the role it defines must not be
        # able to rewrite the state that defines it.
        Sid      = "SandboxStateObjectsOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${local.bucket_arn}/${var.sandbox_state_key}", "${local.bucket_arn}/${var.sandbox_state_key}.tflock"]
      },
    ]
  }

  bucket_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "ThisAccountOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { StringNotEquals = { "aws:PrincipalAccount" = var.sandbox_account_id } }
      },
    ]
  }
}

resource "aws_iam_role" "bootstrap" {
  name                 = local.bootstrap_role_name
  description          = "layered-infra-ops applies the AWS credential broker's sandbox Terraform: one role and its state, nothing else."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = { "managed-by" = "aws-cred-broker" }
}

resource "aws_iam_role_policy" "bootstrap" {
  name   = "broker-sandbox-terraform"
  role   = aws_iam_role.bootstrap.id
  policy = jsonencode(local.permissions_policy)
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
  tags   = { "managed-by" = "aws-cred-broker" }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode(local.bucket_policy)
  # The public access block goes on first, so the policy never lands on a bucket without it.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
