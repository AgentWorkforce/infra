# Plans the example with search on and off, without cloud credentials.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::relay-sessions", region = "us-east-1" }
  }
  mock_resource "aws_opensearch_domain" {
    defaults = { arn = "arn:aws:es:us-east-1:111111111111:domain/mock", endpoint = "vpc-mock.us-east-1.es.amazonaws.com" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:111111111111:certificate/mock" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "mock.abc.us-east-1.rds.amazonaws.com"
      arn                = "arn:aws:rds:us-east-1:111111111111:db:mock"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:rds", kms_key_id = "", secret_status = "active" }]
    }
  }
}

mock_provider "random" {}

variables {
  account_id                 = "111111111111"
  region                     = "us-east-1"
  eks_cluster_name           = "relay"
  domain                     = "ar.example.com"
  database_subnet_ids        = ["subnet-a", "subnet-b"]
  database_security_group_id = "sg-db"
  sessions_bucket_name       = "relay-sessions"
  search_subnet_ids          = ["subnet-a", "subnet-b", "subnet-c"]
  search_security_group_id   = "sg-search"
  search_admin_role_arn      = "arn:aws:iam::111111111111:role/search-admin"
}

run "defaults" {
  command = plan

  assert {
    condition     = length(module.search) == 1
    error_message = "search is on by default"
  }
  assert {
    condition     = toset(aws_acm_certificate.app.subject_alternative_names) == toset(["api.ar.example.com", "cast.ar.example.com", "history.ar.example.com"])
    error_message = "certificate covers the three service hostnames"
  }
  assert {
    condition = alltrue([
      for k in ["indexer/relay/agent-relay/agent-relay-search-indexer", "reader/relay/agent-relay/agent-relay-session-read"] :
      contains(keys(module.search[0].pod_identity_association_ids), k)
    ])
    error_message = "the search roles bind to the ServiceAccounts the chart renders"
  }
}

run "release_name_sets_service_accounts" {
  command = plan

  variables {
    namespace    = "tools"
    release_name = "relay"
  }

  assert {
    condition = alltrue([
      for k in ["indexer/relay/tools/relay-search-indexer", "reader/relay/tools/relay-session-read"] :
      contains(keys(module.search[0].pod_identity_association_ids), k)
    ])
    error_message = "ServiceAccounts follow release_name, not namespace"
  }
  assert {
    condition     = contains(keys(module.sessions_bucket.pod_identity_association_ids), "relay/tools/relay-worker")
    error_message = "the bucket role binds to <release>-worker"
  }
}

run "search_off" {
  command = plan

  variables {
    enable_search            = false
    search_subnet_ids        = []
    search_security_group_id = null
    search_admin_role_arn    = null
  }

  assert {
    condition     = length(module.search) == 0
    error_message = "enable_search = false creates no domain"
  }
}
