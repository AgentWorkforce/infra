# existing_pod_identity_service_accounts: ServiceAccounts that already have a
# Pod Identity association get none from this state. All providers are mocked.
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

variables {
  account_id                  = "111111111111"
  region                      = "us-west-2"
  environment                 = "dev"
  private_subnet_ids          = ["subnet-a", "subnet-b"]
  database_security_group_ids = ["sg-db"]
  search_subnet_ids           = ["subnet-a"]
  search_security_group_ids   = ["sg-search"]
  search_master_user_arn      = "arn:aws:iam::111111111111:role/search-admin"
  eks_cluster_name            = "relay"
}

run "default_creates_every_association" {
  command = plan
  assert {
    condition     = length(module.sessions_bucket.pod_identity_association_ids) == 3 && length(module.search.pod_identity_association_ids) == 2
    error_message = "Without the list every storage and search association is created."
  }
}

run "listed_service_accounts_get_no_association" {
  command = plan
  variables {
    existing_pod_identity_service_accounts = ["agent-relay-worker", "agent-relay-alleyoop", "agent-relay-session-read"]
  }
  assert {
    condition     = keys(module.sessions_bucket.pod_identity_association_ids) == ["relay/agent-relay-dev/agent-relay-session-ingest-api"]
    error_message = "Only the unlisted storage ServiceAccount is bound."
  }
  assert {
    condition     = keys(module.search.pod_identity_association_ids) == ["indexer/relay/agent-relay-dev/agent-relay-search-indexer"]
    error_message = "Only the unlisted search ServiceAccount is bound."
  }
  assert {
    condition     = output.service_accounts.reader == "agent-relay-session-read" && output.service_accounts.storage == ["agent-relay-worker", "agent-relay-alleyoop", "agent-relay-session-ingest-api"]
    error_message = "The ServiceAccount contract stays; only the association is skipped."
  }
}

run "listed_with_history_upload_keeps_upload_bindings" {
  command = plan
  variables {
    kms_key_arn                            = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload                         = { consumer_service_account = "native-ingest-edge" }
    existing_pod_identity_service_accounts = ["agent-relay-worker"]
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.history_control) == 1 && length(aws_eks_pod_identity_association.history_consumer) == 1 && !contains(keys(module.sessions_bucket.pod_identity_association_ids), "relay/agent-relay-dev/agent-relay-worker")
    error_message = "Skipping storage associations never skips the Control or consumer bindings the inbox wall relies on."
  }
}

run "history_consumer_cannot_be_listed" {
  command = plan
  variables {
    kms_key_arn                            = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload                         = { consumer_service_account = "native-ingest-edge" }
    existing_pod_identity_service_accounts = ["native-ingest-edge"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "history_control_cannot_be_listed" {
  command = plan
  variables {
    kms_key_arn                            = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload                         = { consumer_service_account = "native-ingest-edge" }
    existing_pod_identity_service_accounts = ["relay-control"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "desktop_feed_control_cannot_be_listed" {
  command = plan
  variables {
    desktop_feed                           = { profiles = ["p1"] }
    existing_pod_identity_service_accounts = ["relay-control"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "invalid_service_account_name_refused" {
  command = plan
  variables { existing_pod_identity_service_accounts = ["Not_A_ServiceAccount"] }
  expect_failures = [var.existing_pod_identity_service_accounts]
}
