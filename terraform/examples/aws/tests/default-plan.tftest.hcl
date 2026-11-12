# Plan-only fixtures for check_default_plan.py: these compositions must plan
# exactly the resources and outputs recorded in default-plan.golden.json, which
# was generated from origin/main before modules/aws/search and
# modules/aws/postgres gained `enabled`. All providers are mocked.
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

run "default_all_add_ons" {
  command = plan
}

run "default_customer_key" {
  command = plan
  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555"
  }
}

run "default_without_functions" {
  command = plan
  variables {
    enable_functions = false
  }
}

run "default_sessions_read_opt_out" {
  command = plan
  variables {
    search_sessions_bucket_read_enabled = false
  }
}

# check_default_plan.py also requires that this plan has no module.search object.
run "search_off" {
  command = plan
  variables {
    enable_search = false
  }
}
