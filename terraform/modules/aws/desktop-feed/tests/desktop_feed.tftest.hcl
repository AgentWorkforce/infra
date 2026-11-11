mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000", key_id = "00000000-0000-4000-8000-000000000000" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/relay-dev-desktop-feed" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { id = "relay-dev-desktop-feed", arn = "arn:aws:s3:::relay-dev-desktop-feed", region = "us-west-2" }
  }
}

variables {
  name        = "relay-dev-desktop-feed"
  profiles    = ["p1", "p2"]
  bucket_name = "relay-dev-desktop-feed"
  role = {
    pod_identity_associations = [{ cluster_name = "relay-dev", namespace = "agent-relay-dev", service_account = "agent-relay-relay-control" }]
  }
  tags = { Environment = "dev" }
}

run "one_ed25519_signing_key_and_alias_per_profile" {
  command = plan

  assert {
    condition     = length(aws_kms_key.feed) == 2 && alltrue([for k in aws_kms_key.feed : k.key_usage == "SIGN_VERIFY" && k.customer_master_key_spec == "ECC_NIST_EDWARDS25519" && k.deletion_window_in_days == 30 && k.tags.Environment == "dev"])
    error_message = "Each profile needs its own Ed25519 SIGN_VERIFY key."
  }
  assert {
    condition     = aws_kms_alias.feed["p1"].name == "alias/relay-dev-desktop-feed-p1" && aws_kms_alias.feed["p2"].name == "alias/relay-dev-desktop-feed-p2"
    error_message = "Aliases are alias/<name>-<profile>."
  }
  assert {
    condition     = alltrue([for k in aws_kms_key.feed : jsondecode(k.policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:root" && length(jsondecode(k.policy).Statement) == 1])
    error_message = "Key policy delegates to IAM in this account only."
  }
}

run "private_bucket_role_and_pod_identity" {
  assert {
    condition     = length(module.bucket) == 1 && module.bucket[0].bucket_name == "relay-dev-desktop-feed" && module.bucket[0].access_role_arn == null
    error_message = "A private bucket is created through object-storage without its own role."
  }
  assert {
    condition     = aws_iam_role.control[0].name == "relay-dev-desktop-feed" && aws_iam_role.control[0].path == "/" && jsondecode(aws_iam_role.control[0].assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "The Control role is trusted by EKS Pod Identity."
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.control) == 1 && aws_eks_pod_identity_association.control["relay-dev/agent-relay-dev/agent-relay-relay-control"].namespace == "agent-relay-dev"
    error_message = "Control's ServiceAccount is associated in the given namespace."
  }
  assert {
    condition = jsondecode(aws_iam_role_policy.control[0].policy).Statement == [
      { Sid = "SignFeedManifests", Effect = "Allow", Action = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"], Resource = [for k in aws_kms_key.feed : k.arn] },
      { Sid = "ListFeedBucket", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = ["arn:aws:s3:::relay-dev-desktop-feed"] },
      { Sid = "ReadWriteFeedObjects", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = ["arn:aws:s3:::relay-dev-desktop-feed/desktop-feed/*"] },
    ]
    error_message = "Policy grants exactly sign/public-key/describe on the feed keys and object access under the prefix."
  }
  assert {
    condition = output.control_env == {
      SELFHOST_DESKTOP_FEED_SIGNER          = "awskms"
      SELFHOST_DESKTOP_FEED_STORAGE         = "s3"
      SELFHOST_DESKTOP_FEED_KMS_REGION      = "us-west-2"
      SELFHOST_DESKTOP_FEED_KMS_KEY_ALIASES = jsonencode({ p1 = "alias/relay-dev-desktop-feed-p1", p2 = "alias/relay-dev-desktop-feed-p2" })
      SELFHOST_DESKTOP_FEED_S3_BUCKET       = "relay-dev-desktop-feed"
      SELFHOST_DESKTOP_FEED_S3_REGION       = "us-west-2"
      SELFHOST_DESKTOP_FEED_S3_PREFIX       = "desktop-feed"
    }
    error_message = "control_env maps directly to Control's SELFHOST_DESKTOP_FEED_* settings."
  }
}

run "existing_bucket_prefix_and_existing_role" {
  command = plan

  variables {
    create_bucket = false
    bucket_name   = "existing-shared-bucket"
    prefix        = "sites/dev/desktop-feed"
    role          = { create = false }
  }

  assert {
    condition     = length(module.bucket) == 0 && length(aws_iam_role.control) == 0 && length(aws_iam_role_policy.control) == 0 && length(aws_eks_pod_identity_association.control) == 0
    error_message = "No bucket or IAM is created for an existing bucket and role."
  }
  assert {
    condition     = output.role_arn == null && jsondecode(output.policy_json).Statement[2].Resource == ["arn:aws:s3:::existing-shared-bucket/sites/dev/desktop-feed/*"]
    error_message = "policy_json scopes objects to the existing bucket's prefix."
  }
  assert {
    condition     = output.control_env.SELFHOST_DESKTOP_FEED_S3_BUCKET == "existing-shared-bucket" && output.control_env.SELFHOST_DESKTOP_FEED_S3_REGION == "us-west-2" && output.control_env.SELFHOST_DESKTOP_FEED_S3_PREFIX == "sites/dev/desktop-feed"
    error_message = "control_env names the existing bucket and prefix."
  }
}

run "pippen_path_and_boundary" {
  command = plan

  variables {
    role = {
      path                     = "/pippen/workload/"
      permissions_boundary_arn = "arn:aws:iam::111111111111:policy/pippen-agent-session-boundary"
    }
  }

  assert {
    condition     = aws_iam_role.control[0].path == "/pippen/workload/" && aws_iam_role.control[0].permissions_boundary == "arn:aws:iam::111111111111:policy/pippen-agent-session-boundary"
    error_message = "Role path and permissions boundary pass through."
  }
}

run "dotted_bucket_rejected" {
  command = plan
  variables {
    bucket_name = "relay.dev.feed"
  }
  expect_failures = [var.bucket_name]
}

run "unsafe_prefix_rejected" {
  command = plan
  variables {
    prefix = "desktop-feed/../other"
  }
  expect_failures = [var.prefix]
}

run "slash_wrapped_prefix_rejected" {
  command = plan
  variables {
    prefix = "/desktop-feed/"
  }
  expect_failures = [var.prefix]
}

run "no_profiles_rejected" {
  command = plan
  variables {
    profiles = []
  }
  expect_failures = [var.profiles]
}

run "invalid_profile_rejected" {
  command = plan
  variables {
    profiles = ["bad profile"]
  }
  expect_failures = [var.profiles]
}
