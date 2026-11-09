mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::relay-sessions"
      region = "us-west-2"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/relay-sessions"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-west-2"
    }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
}

variables {
  bucket_name = "relay-sessions"
}

run "defaults_are_private_and_encrypted" {
  command = apply

  assert {
    condition = (
      aws_s3_bucket_public_access_block.this.block_public_acls &&
      aws_s3_bucket_public_access_block.this.block_public_policy &&
      aws_s3_bucket_public_access_block.this.ignore_public_acls &&
      aws_s3_bucket_public_access_block.this.restrict_public_buckets
    )
    error_message = "Every public access block setting must be on."
  }
  assert {
    condition     = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "SSE-KMS by default."
  }
  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Enabled"
    error_message = "Versioning is on by default."
  }
  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy is off by default."
  }
  assert {
    condition     = contains([for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Sid], "DenyInsecureTransport")
    error_message = "The bucket policy must deny non-TLS requests."
  }
  assert {
    condition     = one([for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Condition.NumericLessThan["s3:TlsVersion"] if s.Sid == "DenyTLSBelow12"]) == "1.2"
    error_message = "The bucket policy must deny TLS below 1.2."
  }
  assert {
    condition     = length(aws_iam_role.access) == 0
    error_message = "No role unless access_role is set."
  }
}

run "pod_identity_role_is_scoped_to_the_bucket" {
  command = apply

  variables {
    access_role = {
      name     = "relay-sessions"
      prefixes = ["96bulls/"]
      pod_identity_associations = [
        { cluster_name = "relay", namespace = "agent-relay", service_account = "agent-relay-worker" },
        { cluster_name = "relay", namespace = "agent-relay", service_account = "agent-relay-alleyoop" },
      ]
    }
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.access) == 2
    error_message = "One association per service account."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role.access[0].assume_role_policy).Statement[0].Principal.Service == null ? [] : flatten([jsondecode(aws_iam_role.access[0].assume_role_policy).Statement[0].Principal.Service]), "pods.eks.amazonaws.com")
    error_message = "The role must trust EKS Pod Identity."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.access[0].policy).Statement : !contains(flatten([s.Resource]), "*")])
    error_message = "The workload policy must not grant Resource \"*\"."
  }
  assert {
    condition     = contains(flatten([for s in jsondecode(aws_iam_role_policy.access[0].policy).Statement : s.Resource if s.Sid == "ReadWriteObjects"]), "arn:aws:s3:::relay-sessions/96bulls/*")
    error_message = "Object access is limited to the prefix."
  }
}

run "bucket_name_is_validated" {
  command = plan

  variables {
    bucket_name = "Not_A_Bucket"
  }

  expect_failures = [var.bucket_name]
}

run "irsa_needs_an_oidc_provider" {
  command = plan

  variables {
    access_role = {
      name                  = "relay-sessions"
      irsa_service_accounts = [{ namespace = "agent-relay", service_account = "agent-relay-worker" }]
    }
  }

  expect_failures = [var.access_role]
}

run "object_lock_requires_versioning" {
  command = plan

  variables {
    object_lock_enabled = true
    versioning_enabled  = false
  }

  expect_failures = [aws_s3_bucket_versioning.this]
}

run "bucket_key_grant_is_partition_aware" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/abc"
    access_role = { name = "relay-sessions" }
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.access[0].policy).Statement : s.Condition.StringEquals["kms:ViaService"] if s.Sid == "UseBucketKey"]) == "s3.us-west-2.amazonaws.com"
    error_message = "kms:ViaService is s3.<region>.<partition dns suffix>."
  }
}

run "irsa_trust" {
  command = plan

  variables {
    access_role = {
      name                  = "relay-sessions"
      oidc_provider_arn     = "arn:aws:iam::111111111111:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/ABC"
      irsa_service_accounts = [{ namespace = "agent-relay", service_account = "agent-relay-worker" }]
    }
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role.access[0].assume_role_policy).Statement : s.Condition.StringEquals["oidc.eks.us-west-2.amazonaws.com/id/ABC:sub"] if s.Sid == "Irsa"]) == ["system:serviceaccount:agent-relay:agent-relay-worker"]
    error_message = "IRSA trust names the service account subject."
  }
}
