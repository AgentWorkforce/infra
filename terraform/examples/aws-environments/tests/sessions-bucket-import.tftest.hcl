# sessions_bucket_import: adopt an existing bucket with both RDS and OpenSearch
# opted out. check_sessions_bucket_import.py inspects the native plan of
# "import_existing_bucket" (import IDs, no destroy/replace). All providers
# are mocked; no AWS request is made.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/deployer/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  # Realistic values: OpenTofu fills computed attributes at plan time, and
  # the provider validates ARNs.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::relay-sessions", region = "us-west-2" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-west-2:111111111111:mock", url = "https://sqs.us-west-2.amazonaws.com/111111111111/mock" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-west-2:111111111111:function:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-west-2:111111111111:rule/mock" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000", key_id = "00000000-0000-4000-8000-000000000000" }
  }
  mock_resource "aws_opensearch_domain" {
    defaults = { arn = "arn:aws:es:us-west-2:111111111111:domain/mock", endpoint = "vpc-mock.us-west-2.es.amazonaws.com" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "mock.abc.us-west-2.rds.amazonaws.com"
      arn                = "arn:aws:rds:us-west-2:111111111111:db:mock"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds", kms_key_id = "", secret_status = "active" }]
    }
  }
}

mock_provider "random" {}

# Mock providers cannot import; these stand in for what AWS returns for the
# existing bucket and its configuration. aws_s3_bucket_policy carries a
# provider resource identity that a mock cannot fill, so the native-plan run
# skips its import; "import_targets" proves its import ID without planning it.
override_resource {
  override_during = plan
  target          = module.sessions_bucket.aws_s3_bucket.this
  values          = { id = "existing-relay-sessions", bucket = "existing-relay-sessions", arn = "arn:aws:s3:::existing-relay-sessions", region = "us-west-2" }
}
override_resource {
  override_during = plan
  target          = module.sessions_bucket.aws_s3_bucket_public_access_block.this
  values          = { id = "existing-relay-sessions", bucket = "existing-relay-sessions", region = "us-west-2" }
}
override_resource {
  override_during = plan
  target          = module.sessions_bucket.aws_s3_bucket_ownership_controls.this
  values          = { id = "existing-relay-sessions", bucket = "existing-relay-sessions", region = "us-west-2" }
}
override_resource {
  override_during = plan
  target          = module.sessions_bucket.aws_s3_bucket_server_side_encryption_configuration.this
  values          = { id = "existing-relay-sessions", bucket = "existing-relay-sessions", region = "us-west-2" }
}
override_resource {
  override_during = plan
  target          = module.sessions_bucket.aws_s3_bucket_versioning.this
  values          = { id = "existing-relay-sessions", bucket = "existing-relay-sessions", region = "us-west-2" }
}
override_resource {
  override_during = plan
  target          = module.sessions_bucket.aws_s3_bucket_lifecycle_configuration.this[0]
  values          = { id = "existing-relay-sessions", bucket = "existing-relay-sessions", region = "us-west-2", expected_bucket_owner = "", transition_default_minimum_object_size = "all_storage_classes_128K" }
}

variables {
  account_id             = "111111111111"
  region                 = "us-west-2"
  environment            = "prod"
  environment_class      = "production"
  eks_cluster_name       = "relay"
  enable_database        = false
  enable_search          = false
  sessions_bucket_name   = "existing-relay-sessions"
  sessions_bucket_import = true
  kms_key_arn            = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
  history_upload         = { consumer_service_account = "native-ingest-edge" }
}

run "import_targets" {
  command = plan
  plan_options {
    target = [terraform_data.environment_contract]
  }
  assert {
    condition     = jsonencode(local.sessions_bucket_import_ids) == jsonencode({ for k in ["bucket", "public_access_block", "ownership_controls", "server_side_encryption_configuration", "versioning", "lifecycle_configuration", "policy"] : k => "existing-relay-sessions" })
    error_message = "The bucket and all six configuration resources import by the bucket name."
  }
}

# check_sessions_bucket_import.py inspects this native plan.
run "import_existing_bucket" {
  command = plan
  variables { sessions_bucket_import_skip = ["policy"] }
  assert {
    condition     = output.verification.postgres == null && output.verification.search == null && length(aws_iam_role.history_consumer) == 1
    error_message = "Import composes with both opt-outs and history uploads."
  }
}

run "import_skips_absent_configuration" {
  command = plan
  plan_options {
    target = [terraform_data.environment_contract]
  }
  variables { sessions_bucket_import_skip = ["policy", "lifecycle_configuration"] }
  assert {
    condition     = toset(keys(local.sessions_bucket_import_ids)) == toset(["bucket", "ownership_controls", "public_access_block", "server_side_encryption_configuration", "versioning"])
    error_message = "Skipped configurations are not imported; the bucket always is."
  }
}

run "import_requires_a_bucket_name" {
  command = plan
  variables { sessions_bucket_name = null }
  expect_failures = [var.sessions_bucket_import]
}

run "alchemy_bucket_refused" {
  command = plan
  variables { sessions_bucket_name = "relayhistory-pipeline-aws-sessions-prod-abc123" }
  expect_failures = [var.sessions_bucket_import]
}

run "skip_names_only_configurations" {
  command = plan
  variables { sessions_bucket_import_skip = ["bucket"] }
  expect_failures = [var.sessions_bucket_import_skip]
}

run "off_by_default_imports_nothing" {
  command = plan
  variables { sessions_bucket_import = false }
  assert {
    condition     = length(local.sessions_bucket_import_ids) == 0
    error_message = "No import unless sessions_bucket_import is true."
  }
}

# The live policy as AWS returns it: one-item lists collapsed to strings,
# reordered, with other statements around the wall.
run "import_unmanaged_policy_and_lifecycle" {
  command = plan
  variables {
    sessions_bucket_unmanaged = ["policy", "lifecycle_configuration"]
  }
  override_data {
    target = data.aws_s3_bucket_policy.sessions_existing[0]
    values = {
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          { Sid = "SomeoneElsesStatement", Effect = "Allow", Principal = { AWS = "arn:aws:iam::111111111111:role/other" }, Action = "s3:GetObject", Resource = "arn:aws:s3:::existing-relay-sessions/other/*" },
          { Sid = "UploadInboxCreateOnly", Effect = "Deny", Principal = "*", Action = "s3:PutObject", Resource = "arn:aws:s3:::existing-relay-sessions/96bulls/.upload-inbox/*", Condition = { Null = { "s3:if-none-match" = "true" } } },
          { Sid = "UploadInboxConsumerOnly", Effect = "Deny", Principal = { AWS = "*" }, Action = ["s3:DeleteObjectVersion", "s3:GetObject", "s3:DeleteObject", "s3:GetObjectVersion"], Resource = "arn:aws:s3:::existing-relay-sessions/96bulls/.upload-inbox/*", Condition = { ArnNotEquals = { "aws:PrincipalArn" = "arn:aws:iam::111111111111:role/agent-relay-prod-history-consumer" } } },
        ]
      })
    }
  }
  assert {
    condition     = length(terraform_data.sessions_policy_wall) == 1 && toset([for s in output.history_upload.bucket_policy_statements_to_merge : s.Sid]) == toset(["DenyInsecureTransport", "DenyTLSBelow12", "UploadInboxConsumerOnly", "UploadInboxCreateOnly"])
    error_message = "With the wall already in the live policy, history_upload plans and publishes the statements to keep merged."
  }
  assert {
    condition     = jsonencode(local.sessions_bucket_import_ids) == jsonencode({ for k in ["bucket", "public_access_block", "ownership_controls", "server_side_encryption_configuration", "versioning"] : k => "existing-relay-sessions" })
    error_message = "Unmanaged configuration is never imported."
  }
}

run "unmanaged_policy_without_the_wall_refuses_history_upload" {
  command = plan
  variables {
    sessions_bucket_unmanaged = ["policy"]
  }
  override_data {
    target = data.aws_s3_bucket_policy.sessions_existing[0]
    values = {
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          { Sid = "UploadInboxConsumerOnly", Effect = "Deny", Principal = "*", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = "arn:aws:s3:::existing-relay-sessions/96bulls/.upload-inbox/*", Condition = { ArnNotEquals = { "aws:PrincipalArn" = "arn:aws:iam::111111111111:role/someone-else" } } },
        ]
      })
    }
  }
  expect_failures = [terraform_data.sessions_policy_wall]
}

run "unmanaged_lifecycle_without_history_upload_check" {
  command = plan
  variables {
    sessions_bucket_unmanaged   = ["lifecycle_configuration"]
    sessions_bucket_import_skip = ["policy"] # a mock cannot import the policy (see above)
  }
  assert {
    condition     = length(terraform_data.sessions_policy_wall) == 0 && !contains(keys(output.history_upload), "bucket_policy_statements_to_merge")
    error_message = "Only an unmanaged policy needs the wall check."
  }
}

run "unmanaged_requires_import" {
  command = plan
  variables {
    sessions_bucket_import    = false
    sessions_bucket_unmanaged = ["policy"]
  }
  expect_failures = [var.sessions_bucket_unmanaged]
}

run "unmanaged_names_only_policy_or_lifecycle" {
  command = plan
  variables { sessions_bucket_unmanaged = ["versioning"] }
  expect_failures = [var.sessions_bucket_unmanaged]
}
