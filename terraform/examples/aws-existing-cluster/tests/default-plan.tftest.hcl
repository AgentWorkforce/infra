# Plan-only fixtures for check_default_plan.py: these compositions must plan
# exactly the resources and outputs recorded in default-plan.golden.json, which
# was generated from origin/main before modules/aws/search and
# modules/aws/postgres gained `enabled`. All providers are mocked.
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

run "default_search_on" {
  command = plan
}

run "default_release_name" {
  command = plan
  variables {
    namespace    = "tools"
    release_name = "relay"
  }
}

run "default_customer_key" {
  command = plan
  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555"
  }
}

# check_default_plan.py also requires that this plan has no module.search object.
run "search_off" {
  command = plan
  variables {
    enable_search            = false
    search_subnet_ids        = []
    search_security_group_id = null
    search_admin_role_arn    = null
  }
}
