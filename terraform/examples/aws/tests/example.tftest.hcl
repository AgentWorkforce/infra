# Plans the whole example with every add-on on, so module wiring (including
# search <-> functions, which reference each other's outputs) stays acyclic.
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
  region                      = "us-west-2"
  eks_cluster_name            = "relay"
  private_subnet_ids          = ["subnet-a", "subnet-b"]
  database_security_group_ids = ["sg-db"]
  sessions_bucket_name        = "relay-sessions"
  enable_search               = true
  search_subnet_ids           = ["subnet-a", "subnet-b", "subnet-c"]
  search_security_group_ids   = ["sg-search"]
  search_master_user_arn      = "arn:aws:iam::111111111111:role/search-admin"
  indexer_service_account     = "agent-relay-search-indexer"
  reader_service_account      = "agent-relay-session-read"
  enable_functions            = true
  function_security_group_ids = ["sg-fn"]
  pipeline_package            = { s3_bucket = "artifacts", s3_key = "session-pipeline.zip" }
}

run "search_service_accounts_must_be_distinct" {
  command = plan

  variables {
    indexer_service_account = "agent-relay-worker"
  }

  expect_failures = [terraform_data.service_account_checks]
}

run "all_add_ons_plan" {
  command = plan

  assert {
    condition     = !module.functions[0].activation_enabled
    error_message = "Preparing shared-database infrastructure must not activate unqualified application processing."
  }

  assert {
    condition = toset(keys(module.search[0].pod_identity_association_ids)) == toset([
      "indexer/relay/agent-relay/agent-relay-search-indexer",
      "reader/relay/agent-relay/agent-relay-session-read",
    ])
    error_message = "The indexer and reader ServiceAccounts each get their own role's Pod Identity association."
  }
}

run "shared_database_service_layout" {
  command = apply
  assert {
    condition     = output.postgres_service_bindings.control.database == "relaycontrol" && output.postgres_service_bindings.hoopdb.database == "relaycontrol" && output.postgres_service_bindings.relaycast.database == "relaycontrol"
    error_message = "The thin AWS composition must use one database for all service schemas."
  }
  assert {
    condition     = output.postgres_service_bindings.control.schema != output.postgres_service_bindings.hoopdb.schema && !output.postgres_topology.application_sql_ready
    error_message = "Distinct schema bindings are required, with no unsupported SQL-ready claim."
  }
}

run "rds_internal_database_refused" {
  command = plan
  variables { application_database_name = "rdsadmin" }
  expect_failures = [var.application_database_name]
}
