data "aws_caller_identity" "current" {}

locals {
  name       = "${var.name_prefix}-${var.environment}"
  namespace  = coalesce(var.namespace, "agent-relay-${var.environment}")
  production = var.environment_class == "production"
  profiles = {
    development = { database_class = "db.t4g.micro", storage = 20, max_storage = 100, backups = 7, multi_az = false, search_type = "t3.small.search", search_storage = 20 }
    staging     = { database_class = "db.t4g.medium", storage = 100, max_storage = 500, backups = 14, multi_az = true, search_type = "m7g.large.search", search_storage = 100 }
    production  = { database_class = "db.r7g.large", storage = 100, max_storage = 1000, backups = 35, multi_az = true, search_type = "r7g.large.search", search_storage = 200 }
  }
  profile = local.profiles[var.environment_class]
  tags = merge(var.tags, {
    Environment      = var.environment
    EnvironmentClass = var.environment_class
    ManagedBy        = "terraform"
    }, var.pippen == null ? {} : {
    "pippen:sandbox" = "true"
    "pippen:agent"   = var.pippen.agent
    "pippen:session" = var.pippen.session_id
  })
  role_path             = var.pippen == null ? "/" : "/pippen/workload/"
  boundary              = var.pippen == null ? null : "arn:aws:iam::${var.account_id}:policy/pippen-agent-session-boundary"
  storage_prefix        = "proofs/${var.environment}/"
  search_indexer_sa     = "${var.release_name}-search-indexer"
  search_reader_sa      = "${var.release_name}-session-read"
  external_runtime_arns = var.existing_runtime_roles == null ? [] : compact(values(var.existing_runtime_roles))
  indexer_role_arn      = var.existing_runtime_roles == null ? module.search.indexer_role_arn : var.existing_runtime_roles.indexer_role_arn
  reader_role_arn       = var.existing_runtime_roles == null ? module.search.reader_role_arn : var.existing_runtime_roles.reader_role_arn
  sessions_bucket_name  = "${local.name}-${var.account_id}-${var.region}-sessions"
  # The search indexer and session-read API read session objects from this
  # environment's own bucket, so grant it by default, with the key that
  # encrypts it (null: the AWS-managed aws/s3 key needs no key grant).
  # search_sessions_bucket_read remains an explicit, validated equivalent.
  search_sessions_bucket_read = !var.search_sessions_bucket_read_enabled ? null : var.search_sessions_bucket_read != null ? var.search_sessions_bucket_read : {
    bucket_arn  = "arn:aws:s3:::${local.sessions_bucket_name}"
    kms_key_arn = var.kms_key_arn
  }
}

resource "terraform_data" "environment_contract" {
  input = { account_id = var.account_id, environment = var.environment }

  lifecycle {
    precondition {
      condition     = length(local.name) <= 21
      error_message = "name_prefix-environment must fit in 21 characters (the OpenSearch name adds -search)."
    }
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "The AWS caller is in another account."
    }
    precondition {
      condition = startswith(var.search_master_user_arn, "arn:aws:iam::${var.account_id}:role/") && !contains([
        "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-search-indexer",
        "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-search-reader",
        "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-session-pipeline",
        "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-sessions",
        "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-desktop-feed",
      ], var.search_master_user_arn)
      error_message = "OpenSearch administration requires a separate role in this environment's account."
    }
    precondition {
      condition = var.search_sessions_bucket_read == null ? true : (
        var.search_sessions_bucket_read_enabled &&
        var.search_sessions_bucket_read.bucket_arn == "arn:aws:s3:::${local.sessions_bucket_name}" &&
        var.search_sessions_bucket_read.kms_key_arn == var.kms_key_arn
      )
      error_message = "search_sessions_bucket_read must name this environment's sessions bucket and the kms_key_arn that encrypts it, and cannot be combined with search_sessions_bucket_read_enabled = false."
    }
    precondition {
      condition = var.existing_runtime_roles == null ? true : (
        (var.pipeline_runtime == "lambda") == (var.existing_runtime_roles.pipeline_role_arn != null) &&
        length(distinct(local.external_runtime_arns)) == length(local.external_runtime_arns) &&
        alltrue([for arn in local.external_runtime_arns : startswith(arn, "arn:aws:iam::${var.account_id}:role/") && arn != var.search_master_user_arn && arn != "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-sessions"])
      )
      error_message = "External runtime roles must be distinct same-account roles, separate from administration/storage; supply a pipeline role exactly when pipeline_runtime=lambda."
    }
    precondition {
      condition     = !local.production || (var.deletion_protection && length(var.search_subnet_ids) == 3)
      error_message = "Production requires database deletion protection and three OpenSearch AZ subnets."
    }
    precondition {
      condition     = var.postgres_engine_mode != "aurora" || (var.aurora_engine_version != null && var.database_instance_class != null)
      error_message = "Aurora requires an explicit engine version and compatible instance class."
    }
    precondition {
      condition     = var.pipeline_runtime != "lambda" || (var.lambda_package != null && length(var.function_security_group_ids) > 0)
      error_message = "Lambda mode requires a compatible package and private function security groups."
    }
    precondition {
      condition     = !var.activate_lambda || (var.pipeline_runtime == "lambda" && var.lambda_runtime_bindings != null)
      error_message = "activate_lambda requires pipeline_runtime=lambda and explicit compatible artifact/provider/TLS bindings."
    }
    precondition {
      condition     = !var.activate_lambda
      error_message = "Automatic Lambda activation is held: the per-service database/bootstrap/runtime contract is not qualified. Provision inactive infrastructure; qualification requires a reviewed implementation change, not an acknowledgement flag."
    }
    precondition {
      condition = var.lambda_runtime_bindings == null ? true : (
        var.pipeline_runtime == "lambda" && startswith(var.lambda_runtime_bindings.search_index, "${local.name}-")
      )
      error_message = "Lambda runtime bindings require lambda mode and an index prefixed by name_prefix-environment-."
    }
    precondition {
      condition = var.lambda_package == null ? true : (
        (try(var.lambda_package.s3_key, null) == null || try(length(trimspace(var.lambda_package.s3_object_version)) > 0 && var.lambda_package.s3_object_version != "null", false)) &&
        (try(var.lambda_package.filename, null) == null || can(regex("^[A-Za-z0-9+/]{43}=$", var.lambda_package.source_code_hash)))
      )
      error_message = "Lambda S3 packages need an object version; local packages need source_code_hash."
    }
    precondition {
      condition = var.pippen == null ? true : (
        startswith(var.name_prefix, "pippen-sbx-") &&
        data.aws_caller_identity.current.arn == "arn:aws:sts::${var.account_id}:assumed-role/agent-session/agent-${var.pippen.session_id}"
      )
      error_message = "Pippen requires a pippen-sbx- prefix and the exact allocated agent-session caller."
    }
  }
}

module "postgres" {
  #checkov:skip=CKV_AWS_157:Development intentionally uses one AZ; staging and production select Multi-AZ through the class profile.
  #checkov:skip=CKV_AWS_133:Every class profile sets backups (7/14/35 days); Checkov cannot resolve the dynamic map lookup. The live verifier checks the configured value.
  source = "../../modules/aws/postgres"

  name                   = "${local.name}-pg"
  database_name          = var.application_database_name
  engine_mode            = var.postgres_engine_mode
  engine_version         = var.postgres_engine_mode == "aurora" ? coalesce(var.aurora_engine_version, "17") : "17"
  instance_class         = coalesce(var.database_instance_class, local.profile.database_class)
  subnet_ids             = var.private_subnet_ids
  vpc_security_group_ids = var.database_security_group_ids
  kms_key_arn            = var.kms_key_arn
  multi_az               = local.profile.multi_az
  allocated_storage      = local.profile.storage
  max_allocated_storage  = local.profile.max_storage
  backup_retention_days  = local.profile.backups
  deletion_protection    = var.deletion_protection
  skip_final_snapshot    = false
  tags                   = local.tags

  depends_on = [terraform_data.environment_contract]
}

module "sessions_bucket" {
  source = "../../modules/aws/object-storage"

  bucket_name   = local.sessions_bucket_name
  kms_key_arn   = var.kms_key_arn
  force_destroy = false
  access_role = {
    name                     = "${local.name}-sessions"
    path                     = local.role_path
    permissions_boundary_arn = local.boundary
    pod_identity_associations = [for sa in ["worker", "alleyoop", "session-ingest-api"] : {
      cluster_name    = var.eks_cluster_name
      namespace       = local.namespace
      service_account = "${var.release_name}-${sa}"
    }]
  }
  history_upload = local.history_upload_enabled ? {
    name                     = "${local.name}-desktop-upload"
    path                     = local.role_path
    permissions_boundary_arn = local.boundary
    key_root                 = var.history_upload.key_root
    control_role_arn         = local.history_control_role_arn
    consumer_role_arns       = [aws_iam_role.history_consumer[0].arn]
  } : null
  tags = local.tags

  depends_on = [terraform_data.environment_contract]
}

module "search" {
  #checkov:skip=CKV_AWS_318:Dedicated masters are enabled for production; smaller development/staging classes intentionally omit them.
  source = "../../modules/aws/search"

  domain_name                   = "${local.name}-search"
  engine_version                = var.search_engine_version
  subnet_ids                    = var.search_subnet_ids
  security_group_ids            = var.search_security_group_ids
  kms_key_arn                   = var.kms_key_arn
  master_user_arn               = var.search_master_user_arn
  instance_type                 = coalesce(var.search_instance_type, local.profile.search_type)
  instance_count                = length(var.search_subnet_ids)
  dedicated_master_enabled      = local.production
  multi_az_with_standby_enabled = local.production
  ebs_volume_size               = local.profile.search_storage
  workload_roles = {
    create                   = var.existing_runtime_roles == null
    name_prefix              = "${local.name}-search"
    path                     = local.role_path
    permissions_boundary_arn = local.boundary
    indexer_service_accounts = [{ cluster_name = var.eks_cluster_name, namespace = local.namespace, service_account = local.search_indexer_sa }]
    reader_service_accounts  = [{ cluster_name = var.eks_cluster_name, namespace = local.namespace, service_account = local.search_reader_sa }]
  }
  sessions_bucket_read      = local.search_sessions_bucket_read
  additional_principal_arns = distinct(concat(local.external_runtime_arns, var.pipeline_runtime == "lambda" ? [module.pipeline[0].execution_role_arn] : []))
  tags                      = local.tags

  depends_on = [terraform_data.environment_contract]
}

# Off by default. Control's own Pod Identity role: Pod Identity allows one role
# per ServiceAccount, so nothing else may associate Control's ServiceAccount.
module "desktop_feed" {
  source = "../../modules/aws/desktop-feed"
  count  = var.desktop_feed == null ? 0 : 1

  name        = "${local.name}-desktop-feed"
  profiles    = var.desktop_feed.profiles
  bucket_name = "${local.name}-${var.account_id}-${var.region}-desktop-feed"
  prefix      = var.desktop_feed.prefix
  role = {
    path                     = local.role_path
    permissions_boundary_arn = local.boundary
    pod_identity_associations = [{
      cluster_name    = var.eks_cluster_name
      namespace       = local.namespace
      service_account = var.desktop_feed.service_account
    }]
  }
  tags = local.tags

  depends_on = [terraform_data.environment_contract]
}

module "pipeline" {
  source = "../../modules/aws/functions"
  count  = var.pipeline_runtime == "lambda" ? 1 : 0

  name                         = local.name
  enabled                      = var.activate_lambda
  bucket_name                  = module.sessions_bucket.bucket_name
  bucket_kms_key_arn           = var.kms_key_arn
  package                      = var.lambda_package == null ? {} : var.lambda_package
  vpc_subnet_ids               = var.private_subnet_ids
  vpc_security_group_ids       = var.function_security_group_ids
  existing_execution_role_arn  = var.existing_runtime_roles == null ? null : var.existing_runtime_roles.pipeline_role_arn
  role_path                    = local.role_path
  permissions_boundary_arn     = local.boundary
  search_index_enabled         = true
  environment                  = local.lambda_shared_environment
  additional_policy_statements = jsondecode(module.search.indexer_policy_json).Statement
  tags                         = local.tags

  depends_on = [terraform_data.environment_contract]
}

module "chief_execution_node" {
  source = "../../modules/aws/chief-execution-node"
  count  = var.chief_execution_node == null ? 0 : 1

  name                     = "${local.name}-chief-exec"
  subnet_id                = var.chief_execution_node.subnet_id
  kms_key_arn              = var.kms_key_arn
  instance_type            = var.chief_execution_node.instance_type
  root_volume_size_gb      = var.chief_execution_node.root_volume_size_gb
  relay_base_url           = var.chief_execution_node.relay_base_url
  node_runtime             = var.chief_execution_node.node_runtime
  relay_node               = var.chief_execution_node.relay_node
  harness                  = var.chief_execution_node.harness
  bridge                   = var.chief_execution_node.bridge
  repositories             = var.chief_execution_node.repositories
  iam_path                 = local.role_path
  permissions_boundary_arn = local.boundary
  tags                     = local.tags

  depends_on = [terraform_data.environment_contract]
}

# No SQL provider, passwords or privileged bootstrap credentials enter this
# contract. Each service keeps its own complete binding for a later split.
module "postgres_layout" {
  source          = "../../modules/postgres-layout"
  host            = module.postgres.host
  port            = module.postgres.port
  database        = module.postgres.initial_database
  forbidden_roles = [module.postgres.master_username]
  # One instance, separate logical databases. These are non-secret targets;
  # a reviewed SQL bootstrap must create/own them before application activation.
  service_databases = merge({ control = module.postgres.initial_database }, var.service_database_names)
  services = {
    control   = { schema = "public", migration_role = "control_owner", runtime_role = "control_api_runtime" }
    hoopdb    = { schema = "sessions", migration_role = "hoop", runtime_role = "sessions_pipeline_runtime" }
    relaycast = { schema = "public", migration_role = "relaycast_owner", runtime_role = "relaycast_runtime" }
    relayfile = { schema = "public", migration_role = "relayfile_owner", runtime_role = "relayfile_runtime" }
  }
}
