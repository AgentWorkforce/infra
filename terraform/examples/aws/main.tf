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
  region = var.region

  default_tags {
    tags = var.tags
  }
}

locals {
  # The ServiceAccounts the agent-relay chart creates for the sessions
  # pipeline (<release>-worker, <release>-alleyoop; values-eks.yaml).
  sessions_service_accounts = [
    for sa in ["worker", "alleyoop"] : {
      cluster_name    = var.eks_cluster_name
      namespace       = var.namespace
      service_account = "${var.release_name}-${sa}"
    }
  ]
}

# Each Pod Identity ServiceAccount takes one role: the search ServiceAccounts
# must differ from each other and from the sessions worker and alleyoop.
resource "terraform_data" "service_account_checks" {
  lifecycle {
    precondition {
      condition = length(compact([var.indexer_service_account, var.reader_service_account])) == length(distinct(compact([var.indexer_service_account, var.reader_service_account]))) && length(setintersection(
        toset(compact([var.indexer_service_account, var.reader_service_account])),
        toset([for sa in local.sessions_service_accounts : sa.service_account]),
      )) == 0
      error_message = "indexer_service_account and reader_service_account must differ from each other and from <release>-worker / <release>-alleyoop (one Pod Identity association per ServiceAccount)."
    }
  }
}

# One RDS writer/database, with isolated service schemas. The layout output
# is a target contract; schema-aware application bootstrap remains required.
module "postgres" {
  source = "../../modules/aws/postgres"

  name                   = "${var.name}-pg"
  database_name          = var.application_database_name
  engine_mode            = var.postgres_engine_mode
  engine_version         = var.postgres_engine_mode == "aurora" ? var.aurora_engine_version : "17"
  subnet_ids             = var.private_subnet_ids
  vpc_security_group_ids = var.database_security_group_ids
  kms_key_arn            = var.kms_key_arn
  tags                   = var.tags
}

# Session objects (Locker), read and written by the worker and alleyoop pods
# through EKS Pod Identity.
module "sessions_bucket" {
  source = "../../modules/aws/object-storage"

  bucket_name = var.sessions_bucket_name
  kms_key_arn = var.kms_key_arn
  access_role = {
    name                      = "${var.name}-sessions"
    pod_identity_associations = local.sessions_service_accounts
  }
  tags = var.tags
}

# Optional: OpenSearch as the transcript search index (replaces ClickHouse;
# the default stays Postgres pg_trgm). Needs the services' OpenSearch backend.
module "search" {
  source = "../../modules/aws/search"
  count  = var.enable_search ? 1 : 0

  domain_name        = "${var.name}-search"
  subnet_ids         = var.search_subnet_ids
  security_group_ids = var.search_security_group_ids
  kms_key_arn        = var.kms_key_arn
  master_user_arn    = var.search_master_user_arn
  # Separate roles for the indexer (write) and the session read API (read
  # only), each bound to its own ServiceAccount: Pod Identity allows one role
  # per ServiceAccount, and the worker and alleyoop ServiceAccounts already
  # carry the sessions bucket role. The chart needs per-component
  # serviceAccount names for these.
  workload_roles = {
    name_prefix              = "${var.name}-search"
    indexer_service_accounts = var.indexer_service_account == null ? [] : [{ cluster_name = var.eks_cluster_name, namespace = var.namespace, service_account = var.indexer_service_account }]
    reader_service_accounts  = var.reader_service_account == null ? [] : [{ cluster_name = var.eks_cluster_name, namespace = var.namespace, service_account = var.reader_service_account }]
  }
  # In event mode the pipeline Lambda is also an indexer.
  additional_principal_arns = var.enable_functions ? [module.functions[0].execution_role_arn] : []
  tags                      = var.tags
}

# Optional: the sessions pipeline's event-driven mode (S3 -> SQS -> Lambda),
# instead of the long-running worker stages.
module "functions" {
  source = "../../modules/aws/functions"
  count  = var.enable_functions ? 1 : 0

  # Shared-schema runtime/activation remains unqualified. This root can prepare
  # the function and queues, but must not automatically process application data.
  enabled = false

  name                   = var.name
  bucket_name            = module.sessions_bucket.bucket_name
  bucket_kms_key_arn     = var.kms_key_arn
  package                = var.pipeline_package
  vpc_subnet_ids         = var.private_subnet_ids
  vpc_security_group_ids = var.function_security_group_ids
  alarm_actions          = var.alarm_actions
  # With search on, the Lambda writes the index like the indexer role.
  search_index_enabled         = var.enable_search
  additional_policy_statements = var.enable_search ? jsondecode(module.search[0].indexer_policy_json).Statement : []
  tags                         = var.tags
}

# No SQL provider, passwords or privileged bootstrap credentials enter this
# contract. Each service keeps its own complete binding for a later split.
module "postgres_layout" {
  source   = "../../modules/postgres-layout"
  host     = module.postgres.host
  port     = module.postgres.port
  database = module.postgres.initial_database
}
