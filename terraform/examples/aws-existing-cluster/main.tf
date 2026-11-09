# Agent Relay data services for an existing VPC and EKS cluster.
#
# Creates:
#   - one RDS PostgreSQL 17 instance (private, Multi-AZ, TLS only)
#   - one S3 bucket for session data, with a Pod Identity role for the app
#   - an Amazon OpenSearch domain inside the VPC (optional, on by default)
#   - one ACM certificate for the app's four hostnames
#
# Changes nothing in your VPC, subnets or cluster.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = var.tags
  }
}

locals {
  # The Kubernetes ServiceAccounts that read and write session data.
  session_service_accounts = [
    for name in ["worker", "alleyoop", "session-ingest-api"] : {
      cluster_name    = var.eks_cluster_name
      namespace       = var.namespace
      service_account = "${var.release_name}-${name}"
    }
  ]

  # EKS Pod Identity allows one role per ServiceAccount, so search has its own.
  search_indexer_service_account = { cluster_name = var.eks_cluster_name, namespace = var.namespace, service_account = "${var.release_name}-search-indexer" }
  search_reader_service_account  = { cluster_name = var.eks_cluster_name, namespace = var.namespace, service_account = "${var.release_name}-session-read" }

  hostnames = [var.domain, "api.${var.domain}", "cast.${var.domain}", "history.${var.domain}"]
}

module "database" {
  source = "../../modules/aws/postgres"

  name                   = "${var.name}-pg"
  subnet_ids             = var.database_subnet_ids
  vpc_security_group_ids = [var.database_security_group_id]
  instance_class         = var.database_instance_class
  backup_retention_days  = var.database_backup_retention_days
  kms_key_arn            = var.kms_key_arn
}

module "sessions_bucket" {
  source = "../../modules/aws/object-storage"

  bucket_name = var.sessions_bucket_name
  kms_key_arn = var.kms_key_arn
  access_role = {
    name                      = "${var.name}-sessions"
    pod_identity_associations = local.session_service_accounts
  }
}

module "search" {
  source = "../../modules/aws/search"
  count  = var.enable_search ? 1 : 0

  domain_name        = "${var.name}-search"
  subnet_ids         = var.search_subnet_ids
  security_group_ids = [var.search_security_group_id]
  instance_type      = var.search_instance_type
  master_user_arn    = var.search_admin_role_arn
  kms_key_arn        = var.kms_key_arn
  # The indexer (write) and reader (read-only) roles, bound to the ServiceAccounts
  # the chart renders. Both also read session objects from the bucket.
  workload_roles = {
    name_prefix              = "${var.name}-search"
    indexer_service_accounts = [local.search_indexer_service_account]
    reader_service_accounts  = [local.search_reader_service_account]
  }
  sessions_bucket_read = {
    bucket_arn  = module.sessions_bucket.bucket_arn
    kms_key_arn = var.kms_key_arn
  }
}

resource "aws_acm_certificate" "app" {
  domain_name               = var.domain
  subject_alternative_names = slice(local.hostnames, 1, length(local.hostnames))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}
