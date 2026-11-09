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
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/relay-search-role" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:/aws/opensearch/relay-search" }
  }
  mock_resource "aws_opensearch_domain" {
    defaults = {
      arn      = "arn:aws:es:us-west-2:111111111111:domain/relay-search"
      endpoint = "vpc-relay-search-abc.us-west-2.es.amazonaws.com"
    }
  }
}

variables {
  domain_name        = "relay-search"
  subnet_ids         = ["subnet-a", "subnet-b", "subnet-c"]
  security_group_ids = ["sg-search"]
  master_user_arn    = "arn:aws:iam::111111111111:role/search-admin"
  workload_roles = {
    indexer_service_accounts = [{ cluster_name = "relay", namespace = "agent-relay", service_account = "agent-relay-search-indexer" }]
    reader_service_accounts  = [{ cluster_name = "relay", namespace = "agent-relay", service_account = "agent-relay-session-read" }]
  }
}

run "unset_adds_nothing" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.sessions_read) == 0 && output.sessions_read_policy_json == null
    error_message = "Without the input the module must add no policy."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.workload["indexer"].policy).Statement) == 1 && length(jsondecode(aws_iam_role_policy.workload["reader"].policy).Statement) == 1
    error_message = "The OpenSearch policies must not change."
  }
}

run "set_grants_read_only_on_the_bucket_and_key" {
  command = plan

  variables {
    sessions_bucket_read = {
      bucket_arn  = "arn:aws:s3:::relay-sessions"
      kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555"
    }
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy.sessions_read)) == toset(["indexer", "reader"])
    error_message = "Both workload roles need the read policy."
  }
  assert {
    condition     = aws_iam_role_policy.sessions_read["indexer"].name != aws_iam_role_policy.workload["indexer"].name
    error_message = "The read policy must not replace the OpenSearch inline policy."
  }
  assert {
    condition     = aws_iam_role_policy.sessions_read["indexer"].policy == aws_iam_role_policy.sessions_read["reader"].policy
    error_message = "Indexer and reader get the same read-only access."
  }
  assert {
    condition     = toset(flatten([for s in jsondecode(output.sessions_read_policy_json).Statement : s.Action])) == toset(["s3:ListBucket", "s3:GetObject", "kms:Decrypt"])
    error_message = "The policy must grant only list, get and decrypt."
  }
  assert {
    condition = toset(flatten([for s in jsondecode(output.sessions_read_policy_json).Statement : s.Resource])) == toset([
      "arn:aws:s3:::relay-sessions",
      "arn:aws:s3:::relay-sessions/*",
      "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555",
    ])
    error_message = "The policy must name only this bucket, its objects and its key."
  }
  assert {
    condition     = one([for s in jsondecode(output.sessions_read_policy_json).Statement : s.Resource if contains(s.Action, "s3:ListBucket")]) == ["arn:aws:s3:::relay-sessions"] && one([for s in jsondecode(output.sessions_read_policy_json).Statement : s.Resource if contains(s.Action, "s3:GetObject")]) == ["arn:aws:s3:::relay-sessions/*"]
    error_message = "ListBucket applies to the bucket and GetObject to its objects."
  }
  assert {
    condition     = jsondecode(output.sessions_read_policy_json).Statement[2].Condition.StringEquals["kms:ViaService"] == "s3.us-west-2.amazonaws.com"
    error_message = "The key may be used only through S3 in this Region."
  }
}

run "aws_managed_key_needs_no_kms_statement" {
  command = plan

  variables {
    sessions_bucket_read = { bucket_arn = "arn:aws:s3:::relay-sessions" }
  }

  assert {
    condition     = length(jsondecode(output.sessions_read_policy_json).Statement) == 2 && !strcontains(output.sessions_read_policy_json, "kms:")
    error_message = "A bucket on the AWS-managed key gets no KMS statement."
  }
}

run "external_roles_only_get_the_policy_document" {
  command = plan

  variables {
    workload_roles       = { create = false }
    sessions_bucket_read = { bucket_arn = "arn:aws:s3:::relay-sessions" }
  }

  assert {
    condition     = length(aws_iam_role_policy.sessions_read) == 0 && output.sessions_read_policy_json != null
    error_message = "External roles are not authored here; the policy is exported for them."
  }
}

run "wildcard_bucket_refused" {
  command = plan

  variables {
    sessions_bucket_read = { bucket_arn = "arn:aws:s3:::*" }
  }

  expect_failures = [var.sessions_bucket_read]
}

run "object_path_refused" {
  command = plan

  variables {
    sessions_bucket_read = { bucket_arn = "arn:aws:s3:::relay-sessions/*" }
  }

  expect_failures = [var.sessions_bucket_read]
}

run "wildcard_key_refused" {
  command = plan

  variables {
    sessions_bucket_read = { bucket_arn = "arn:aws:s3:::relay-sessions", kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/*" }
  }

  expect_failures = [var.sessions_bucket_read]
}

run "key_alias_refused" {
  command = plan

  variables {
    sessions_bucket_read = { bucket_arn = "arn:aws:s3:::relay-sessions", kms_key_arn = "arn:aws:kms:us-west-2:111111111111:alias/sessions" }
  }

  expect_failures = [var.sessions_bucket_read]
}
