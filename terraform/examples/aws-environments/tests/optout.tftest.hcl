# Opt-out compositions: enable_database / enable_search = false. Self-host
# defaults are proven unchanged separately (check_default_plan.py); these runs
# prove what the opt-outs leave out and which inputs they stop requiring.
# check_default_plan.py also asserts the exact planned address set of
# "both_off_minimal_inputs". All providers are mocked.
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

# Only what an environment whose database and search live elsewhere supplies: no database or
# search subnets, security groups or OpenSearch administrator.
variables {
  account_id       = "111111111111"
  region           = "us-west-2"
  environment      = "prod"
  eks_cluster_name = "relay"
  enable_database  = false
  enable_search    = false
}

run "both_off_minimal_inputs" {
  command = plan
  variables { environment_class = "production" }

  assert {
    condition     = length(module.postgres_layout) == 0 && !module.postgres.enabled && !module.search.enabled && length(module.search.pod_identity_association_ids) == 0 && module.search.indexer_role_arn == null && module.search.reader_role_arn == null
    error_message = "Opting out of both must create no database, domain, search role or search Pod Identity association."
  }
  assert {
    condition     = output.verification.postgres == null && output.verification.search == null && output.postgres_service_bindings == null && output.postgres_topology == null
    error_message = "Database and search outputs must be null when opted out."
  }
  assert {
    condition     = output.service_accounts.indexer == null && output.service_accounts.reader == null && output.service_accounts.storage == ["agent-relay-worker", "agent-relay-alleyoop", "agent-relay-session-ingest-api"]
    error_message = "Search ServiceAccounts are not bound; the sessions storage bindings stay."
  }
  assert {
    condition     = output.runtime_role_policy_json.indexer == null && output.runtime_role_policy_json.reader == null && output.runtime_role_policy_json.pipeline == null && !contains(keys(output.runtime_role_policy_json), "sessions_read")
    error_message = "No search runtime policy is proposed without search."
  }
}

# Plan-only and before any apply in this file, so the bucket plans as a fresh
# create; check_default_plan.py asserts its planned name.
run "both_off_existing_bucket_name" {
  command = plan
  variables {
    sessions_bucket_name = "existing-relay-sessions"
    kms_key_arn          = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload       = { consumer_service_account = "native-ingest-edge" }
  }
  assert {
    condition     = length(aws_iam_role.history_consumer) == 1 && length(aws_eks_pod_identity_association.history_control) == 1 && output.verification.postgres == null && output.verification.search == null
    error_message = "History uploads keep their identities with the override and both opt-outs."
  }
}

run "both_off_history_upload" {
  command = apply
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge" }
  }
  assert {
    condition     = output.history_upload.control_values.historyUpload.bucket == module.sessions_bucket.bucket_name && output.verification.storage.bucket == module.sessions_bucket.bucket_name && output.history_upload.control_values.historyUpload.mode == "off" && output.history_upload.control_values.historyUpload.kmsKeyArn == var.kms_key_arn
    error_message = "Direct uploads target the stack's own sessions bucket and KMS key without the database or search."
  }
  assert {
    condition     = aws_eks_pod_identity_association.history_control[0].service_account == "relay-control" && aws_eks_pod_identity_association.history_consumer[0].service_account == "native-ingest-edge" && output.history_upload.control_values.historyUpload.roleArn != null
    error_message = "Control, consumer and desktop upload identities exist with both opted out."
  }
}

run "history_upload_rearm_sweeper" {
  command = plan
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge", rearm_sweeper_service_account = "agent-relay-rearm-sweeper" }
  }
  assert {
    condition     = length(aws_iam_role.rearm_sweeper) == 1 && aws_eks_pod_identity_association.rearm_sweeper[0].service_account == "agent-relay-rearm-sweeper"
    error_message = "The re-arm sweeper gets its own role and Pod Identity association."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.rearm_sweeper[0].policy).Statement :
    s.Effect == "Deny" && contains(flatten([s.Action]), "s3:DeleteObjectVersion") && endswith(s.Resource, "/96bulls/.*")])
    error_message = "Version deletes are denied on every dot-prefixed namespace under the key root."
  }
}

run "history_upload_without_rearm_sweeper" {
  command = plan
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge" }
  }
  assert {
    condition     = length(aws_iam_role.rearm_sweeper) == 0 && length(aws_eks_pod_identity_association.rearm_sweeper) == 0
    error_message = "Without a sweeper ServiceAccount nothing is created."
  }
}

run "rearm_sweeper_refuses_the_ingest_account" {
  command = plan
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge", rearm_sweeper_service_account = "native-ingest-edge" }
  }
  expect_failures = [var.history_upload]
}

run "rearm_sweeper_refuses_a_search_account" {
  command = plan
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge", rearm_sweeper_service_account = "agent-relay-search-indexer" }
  }
  expect_failures = [var.history_upload]
}

run "search_off_database_on" {
  command = plan
  variables {
    environment                 = "dev"
    enable_database             = true
    private_subnet_ids          = ["subnet-a", "subnet-b"]
    database_security_group_ids = ["sg-db"]
  }
  assert {
    condition     = output.verification.postgres.identifier == "agent-relay-dev-pg" && output.postgres_service_bindings.control.database == "relaycontrol" && output.verification.search == null && length(module.search.pod_identity_association_ids) == 0
    error_message = "Search can be opted out alone, without its administrator or subnets."
  }
}

run "database_off_search_on" {
  command = plan
  variables {
    environment               = "dev"
    enable_search             = true
    search_subnet_ids         = ["subnet-a"]
    search_security_group_ids = ["sg-search"]
    search_master_user_arn    = "arn:aws:iam::111111111111:role/search-admin"
  }
  assert {
    condition     = output.verification.postgres == null && output.postgres_service_bindings == null && output.verification.search.domain_name == "agent-relay-dev-search" && length(module.search.pod_identity_association_ids) == 2
    error_message = "The database can be opted out alone; search keeps both workload bindings."
  }
}

run "sessions_bucket_override_reaches_search_read_grant" {
  command = plan
  variables {
    environment                 = "dev"
    enable_database             = true
    enable_search               = true
    private_subnet_ids          = ["subnet-a", "subnet-b"]
    database_security_group_ids = ["sg-db"]
    search_subnet_ids           = ["subnet-a"]
    search_security_group_ids   = ["sg-search"]
    search_master_user_arn      = "arn:aws:iam::111111111111:role/search-admin"
    sessions_bucket_name        = "existing-relay-sessions"
  }
  assert {
    condition = toset(flatten([for s in jsondecode(output.runtime_role_policy_json.sessions_read).Statement : s.Resource])) == toset([
      "arn:aws:s3:::existing-relay-sessions",
      "arn:aws:s3:::existing-relay-sessions/*",
    ])
    error_message = "The search read grant follows the overridden bucket."
  }
}

run "invalid_bucket_name_refused" {
  command = plan
  variables { sessions_bucket_name = "Not_A_Bucket" }
  expect_failures = [var.sessions_bucket_name]
}

run "search_on_requires_administrator" {
  command = plan
  variables {
    enable_search             = true
    search_subnet_ids         = ["subnet-a"]
    search_security_group_ids = ["sg-search"]
  }
  expect_failures = [var.search_master_user_arn]
}

run "search_on_requires_subnets" {
  command = plan
  variables {
    enable_search          = true
    search_master_user_arn = "arn:aws:iam::111111111111:role/search-admin"
  }
  expect_failures = [var.search_subnet_ids]
}

run "database_on_requires_subnets" {
  command = plan
  variables {
    enable_database             = true
    database_security_group_ids = ["sg-db"]
  }
  expect_failures = [var.private_subnet_ids]
}

run "lambda_requires_both" {
  command = plan
  variables {
    environment                 = "dev"
    enable_database             = true
    private_subnet_ids          = ["subnet-a", "subnet-b"]
    database_security_group_ids = ["sg-db"]
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_search_roles_refused_without_search" {
  command = plan
  variables {
    existing_runtime_roles = {
      indexer_role_arn = "arn:aws:iam::111111111111:role/bootstrap/indexer"
      reader_role_arn  = "arn:aws:iam::111111111111:role/bootstrap/reader"
    }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "explicit_search_read_grant_refused_without_search" {
  command = plan
  variables {
    search_sessions_bucket_read = { bucket_arn = "arn:aws:s3:::agent-relay-prod-111111111111-us-west-2-sessions" }
  }
  expect_failures = [terraform_data.environment_contract]
}
