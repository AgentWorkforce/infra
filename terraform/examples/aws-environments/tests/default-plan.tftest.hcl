# Plan-only fixtures for check_default_plan.py: the default (self-host)
# composition, in every add-on combination, must plan exactly the resources and
# values recorded in default-plan.golden.json, which was generated from the
# configuration before enable_database/enable_search existed. Do not set the
# opt-out variables here. All providers are mocked; no AWS request is made.
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


run "default_development" {
  command = plan
}

run "default_staging" {
  command = plan
  variables {
    environment       = "team-a"
    environment_class = "staging"
    search_subnet_ids = ["subnet-a", "subnet-b"]
  }
}

run "default_production" {
  command = plan
  variables {
    environment       = "prod"
    environment_class = "production"
    search_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  }
}

run "default_lambda" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    enable_relayfile            = true
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
}

run "default_external_roles" {
  command = plan
  variables {
    existing_runtime_roles = {
      indexer_role_arn = "arn:aws:iam::111111111111:role/bootstrap/indexer"
      reader_role_arn  = "arn:aws:iam::111111111111:role/bootstrap/reader"
    }
  }
}

run "default_history_upload_and_feed" {
  command = plan
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge" }
    desktop_feed   = { profiles = ["p1"] }
  }
}
