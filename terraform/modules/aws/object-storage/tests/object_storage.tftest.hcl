mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
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
    condition     = contains([for s in jsondecode(aws_s3_bucket_policy.this[0].policy).Statement : s.Sid], "DenyInsecureTransport")
    error_message = "The bucket policy must deny non-TLS requests."
  }
  assert {
    condition     = one([for s in jsondecode(aws_s3_bucket_policy.this[0].policy).Statement : s.Condition.NumericLessThan["s3:TlsVersion"] if s.Sid == "DenyTLSBelow12"]) == "1.2"
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

run "direct_upload_is_write_only_and_consumer_isolated" {
  command = apply
  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = {
      name               = "desktop-upload"
      control_role_arn   = "arn:aws:iam::111111111111:role/control"
      consumer_role_arns = ["arn:aws:iam::111111111111:role/consumer"]
    }
  }
  assert {
    condition     = !one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled
    error_message = "Object-scoped KMS session policies cannot use S3 Bucket Keys."
  }
  assert {
    condition     = jsondecode(aws_iam_role.history_upload[0].assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:role/control" && contains(jsondecode(aws_iam_role.history_upload[0].assume_role_policy).Statement[0].Action, "sts:SetSourceIdentity")
    error_message = "Only Control may assume the upload role, with traceable source identity."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role.history_upload[0].assume_role_policy).Statement[0].Action, "sts:TagSession") && contains(jsondecode(aws_iam_role_policy.history_upload_issuer[0].policy).Statement[0].Action, "sts:TagSession")
    error_message = "Both target trust and Control grant must permit EKS Pod Identity transitive session tags during role chaining."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.history_upload[0].policy).Statement[0].Action == "s3:PutObject" && jsondecode(aws_iam_role_policy.history_upload[0].policy).Statement[0].Resource == "arn:aws:s3:::relay-sessions/96bulls/.upload-inbox/*" && jsondecode(aws_iam_role_policy.history_upload[0].policy).Statement[0].Condition.Null["s3:if-none-match"] == "false"
    error_message = "The client role can create inbox objects only, never read/list/delete transcripts."
  }
  assert {
    condition     = startswith(jsondecode(file("${path.module}/../../../../ci/history-upload/relay-upload-inbox-v1.vectors.json")).objectKey, trimprefix(trimsuffix(jsondecode(aws_iam_role_policy.history_upload[0].policy).Statement[0].Resource, "*"), "arn:aws:s3:::relay-sessions/"))
    error_message = "The frozen cross-repository contract vector must be writable under the IAM namespace."
  }
  assert {
    condition     = one([for s in jsondecode(aws_s3_bucket_policy.this[0].policy).Statement : s.Condition.ArnNotEquals["aws:PrincipalArn"] if s.Sid == "UploadInboxConsumerOnly"]) == ["arn:aws:iam::111111111111:role/consumer"]
    error_message = "Reader/writer roles must not read raw upload objects through broad legacy prefix grants."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.history_upload_issuer[0].policy).Statement[1].Resource == "arn:aws:s3:::relay-sessions/96bulls/.admission-inbox/*/v1/ws=*/m=srv_*/privacy-journal.json"
    error_message = "Control reads only privacy journals, not transcript bodies."
  }
}

run "direct_upload_requires_a_customer_managed_key" {
  command = plan
  variables {
    history_upload = {
      name               = "desktop-upload"
      control_role_arn   = "arn:aws:iam::111111111111:role/control"
      consumer_role_arns = ["arn:aws:iam::111111111111:role/consumer"]
    }
  }
  expect_failures = [aws_iam_role.history_upload]
}

run "unmanaged_policy_and_lifecycle_are_left_alone" {
  command = plan
  variables {
    unmanaged   = ["policy", "lifecycle_configuration"]
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = {
      name               = "desktop-upload"
      control_role_arn   = "arn:aws:iam::111111111111:role/control"
      consumer_role_arns = ["arn:aws:iam::111111111111:role/consumer"]
    }
  }
  assert {
    condition     = length(aws_s3_bucket_policy.this) == 0 && length(aws_s3_bucket_lifecycle_configuration.this) == 0
    error_message = "Unmanaged policy and lifecycle configuration are neither created nor replaced."
  }
  assert {
    condition     = toset([for s in output.upload_wall_statements : s.Sid]) == toset(["UploadInboxConsumerOnly", "UploadInboxCreateOnly"]) && toset([for s in output.bucket_policy_statements : s.Sid]) == toset(["DenyInsecureTransport", "DenyTLSBelow12", "UploadInboxConsumerOnly", "UploadInboxCreateOnly"])
    error_message = "The statements the unmanaged policy must carry are still published."
  }
}

run "unmanaged_rejects_other_resources" {
  command = plan
  variables { unmanaged = ["versioning"] }
  expect_failures = [var.unmanaged]
}
