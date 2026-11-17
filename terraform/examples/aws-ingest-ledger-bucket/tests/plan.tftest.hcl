# Plans the ledger bucket and its grants without cloud credentials.
# No override_during: OpenTofu does not support it, and every asserted value is
# known at plan (the bucket ARN is built from var.bucket_name).
mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::relay-ingest-ledger" }
  }
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
}

variables {
  account_id              = "111111111111"
  region                  = "us-west-2"
  bucket_name             = "relay-ingest-ledger"
  consumer_role_name      = "relay-prod-history-consumer"
  rearm_sweeper_role_name = "relay-prod-rearm-sweeper"
}

run "sse_s3_private_versioned" {
  command = plan
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.ledger.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The default is SSE-S3: no KMS call per ledger request."
  }
  assert {
    condition     = one(aws_s3_bucket_versioning.ledger.versioning_configuration).status == "Enabled"
    error_message = "Versioning is on."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.ledger.block_public_policy && aws_s3_bucket_public_access_block.ledger.restrict_public_buckets
    error_message = "The bucket is never public."
  }
}

run "least_privilege" {
  command = plan
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.consumer.policy).Statement :
    s.Sid == "LedgerObjects" && s.Resource == "arn:aws:s3:::relay-ingest-ledger/96bulls/*"])
    error_message = "The edge reads and writes the key root only."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.rearm_sweeper[0].policy).Statement :
    !contains(flatten([s.Action]), "s3:DeleteObject") && !contains(flatten([s.Action]), "s3:DeleteObjectVersion")])
    error_message = "The sweeper deletes nothing in the ledger bucket."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.rearm_sweeper[0].policy).Statement :
    s.Sid == "LedgerRearmRecords" && contains(s.Resource, "arn:aws:s3:::relay-ingest-ledger/96bulls/.admission-inbox/*/ledger/rearm/*.done/*")])
    error_message = "The sweeper writes only completion and corrupt records."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.consumer.policy).Statement : s if s.Sid == "LedgerKeyViaS3"]) == 0
    error_message = "SSE-S3 needs no key grant."
  }
}

run "sse_kms_with_bucket_keys" {
  command = plan
  variables {
    sse_kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.ledger.rule).bucket_key_enabled
    error_message = "SSE-KMS uses S3 Bucket Keys."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.consumer.policy).Statement :
    s.Sid == "LedgerKeyViaS3" && s.Condition.StringEquals["kms:ViaService"] == "s3.us-west-2.amazonaws.com"])
    error_message = "The key is used through S3 only."
  }
}

run "no_sweeper" {
  command = plan
  variables {
    rearm_sweeper_role_name = null
  }
  assert {
    condition     = length(aws_iam_role_policy.rearm_sweeper) == 0
    error_message = "No sweeper role, no sweeper grant."
  }
}

run "refuses_a_bad_bucket_name" {
  command = plan
  variables {
    bucket_name = "Bad_Bucket"
  }
  expect_failures = [var.bucket_name]
}

run "default_bucket_policy_has_one_statement" {
  command = plan
  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.ledger.policy).Statement) == 1 && jsondecode(aws_s3_bucket_policy.ledger.policy).Statement[0].Sid == "DenyInsecureTransport"
    error_message = "With no cross-account roles the bucket policy is DenyInsecureTransport only."
  }
}

run "cross_account_readers_and_writers" {
  command = plan
  variables {
    cross_account_ledger_reader_role_arns = ["arn:aws:iam::111111111111:role/example-backlog-read"]
    cross_account_ledger_writer_role_arns = ["arn:aws:iam::222222222222:role/example-backlog-write"]
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.ledger.policy).Statement : s.Sid] == ["DenyInsecureTransport", "CrossAccountLedgerList", "CrossAccountLedgerRead", "CrossAccountLedgerWrite"]
    error_message = "DenyInsecureTransport stays first, then List, Read and Write."
  }
  # Filter by Sid first: Terraform 1.11 does not short-circuit &&.
  assert {
    condition = alltrue([for s in jsondecode(aws_s3_bucket_policy.ledger.policy).Statement :
      s.Action == "s3:ListBucket" && s.Resource == "arn:aws:s3:::relay-ingest-ledger"
      && s.Principal.AWS == ["arn:aws:iam::111111111111:role/example-backlog-read", "arn:aws:iam::222222222222:role/example-backlog-write"]
    && s.Condition.StringLike["s3:prefix"] == ["96bulls/.admission-inbox/*", "96bulls/.ledger/fence-authority/.ledger-home.json"] if s.Sid == "CrossAccountLedgerList"])
    error_message = "Readers and writers list only the ledger prefixes."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_s3_bucket_policy.ledger.policy).Statement :
      s.Action == "s3:GetObject" && length(s.Principal.AWS) == 2
    && s.Resource == ["arn:aws:s3:::relay-ingest-ledger/96bulls/.admission-inbox/*/ledger/*", "arn:aws:s3:::relay-ingest-ledger/96bulls/.ledger/fence-authority/.ledger-home.json"] if s.Sid == "CrossAccountLedgerRead"])
    error_message = "Readers and writers get the ledger objects and the home marker."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_s3_bucket_policy.ledger.policy).Statement :
      s.Action == "s3:PutObject" && s.Principal.AWS == ["arn:aws:iam::222222222222:role/example-backlog-write"]
    && s.Resource == "arn:aws:s3:::relay-ingest-ledger/96bulls/.admission-inbox/*/ledger/*" && !can(s.Condition) if s.Sid == "CrossAccountLedgerWrite"])
    error_message = "Only writers put ledger objects, with no SSE condition."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_s3_bucket_policy.ledger.policy).Statement :
    s.Effect == "Deny" || length([for a in flatten([s.Action]) : a if strcontains(a, "Delete") || strcontains(a, "Version")]) == 0])
    error_message = "No cross-account delete or version actions."
  }
}

run "cross_account_readers_only" {
  command = plan
  variables {
    cross_account_ledger_reader_role_arns = ["arn:aws:iam::111111111111:role/example-backlog-read"]
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.ledger.policy).Statement : s.Sid] == ["DenyInsecureTransport", "CrossAccountLedgerList", "CrossAccountLedgerRead"]
    error_message = "No writers, no Write statement."
  }
}

run "refuses_a_bad_cross_account_arn" {
  command = plan
  variables {
    cross_account_ledger_reader_role_arns = ["arn:aws:iam::111111111111:user/example"]
    cross_account_ledger_writer_role_arns = ["not-an-arn"]
  }
  expect_failures = [var.cross_account_ledger_reader_role_arns, var.cross_account_ledger_writer_role_arns]
}

run "refuses_cross_account_with_kms" {
  command = plan
  variables {
    sse_kms_key_arn                       = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    cross_account_ledger_reader_role_arns = ["arn:aws:iam::111111111111:role/example-backlog-read"]
  }
  expect_failures = [aws_s3_bucket_policy.ledger]
}
