output "environment" {
  description = "Environment identity to compare with the separately configured backend before apply."
  value       = { name = var.environment, class = var.environment_class, account_id = var.account_id, region = var.region, namespace = local.namespace, name_prefix = var.name_prefix }
}

output "verification" {
  description = "Non-secret input for the private-runner data-path verifier. Contains secret references, never secret values."
  value = {
    environment       = var.environment
    environment_class = var.environment_class
    name_prefix       = var.name_prefix
    account_id        = var.account_id
    region            = var.region
    namespace         = local.namespace
    pippen            = var.pippen
    postgres = {
      identifier            = "${local.name}-pg"
      master_username       = module.postgres.master_username
      host                  = module.postgres.host
      port                  = module.postgres.port
      database              = module.postgres.initial_database
      secret_arn            = module.postgres.master_user_secret_arn
      resource_arn          = module.postgres.resource_arn
      engine_mode           = module.postgres.engine_mode
      deletion_protection   = var.deletion_protection
      backup_retention_days = local.profile.backups
    }
    storage = {
      bucket   = module.sessions_bucket.bucket_name
      prefix   = local.storage_prefix
      role_arn = module.sessions_bucket.access_role_arn
    }
    search = {
      url              = module.search.url
      domain_name      = module.search.domain_name
      domain_arn       = module.search.domain_arn
      master_role_arn  = var.search_master_user_arn
      indexer_role_arn = local.indexer_role_arn
      reader_role_arn  = local.reader_role_arn
      lambda_role_arn  = var.pipeline_runtime == "lambda" ? module.pipeline[0].execution_role_arn : null
      index_prefix     = "${local.name}-"
    }
    pipeline = var.pipeline_runtime == "lambda" ? {
      function_name = module.pipeline[0].function_name
      function_arn  = module.pipeline[0].function_arn
      image_uri     = try(var.lambda_package.image_uri, null)
    } : null
  }
}

output "pipeline" {
  description = "Lambda runtime bindings, or null in worker mode. Populate the secret out of band and verify actual handler compatibility before activation."
  value = var.pipeline_runtime == "lambda" ? {
    function_name      = module.pipeline[0].function_name
    activation_enabled = module.pipeline[0].activation_enabled
    function_arn       = module.pipeline[0].function_arn
    queue_url          = module.pipeline[0].queue_url
    dlq_url            = module.pipeline[0].dlq_url
    secret_arn         = module.pipeline[0].secret_arn
  } : null
}

output "application_contract" {
  description = "Required full-suite components and selected pipeline mode. This contract does not replace complete Helm values, actor roles, bootstrap or runtime compatibility proof."
  value = {
    pipeline_runtime = var.pipeline_runtime
    components = {
      cloudApi         = true
      dashboard        = true
      sessionsPipeline = true
      relayhistory     = false # History is a pipeline capability, not a standalone target server.
      relaycast        = true
      relayauth        = false # Target services authenticate through Control.
      durableActors    = false
      relayfile        = var.enable_relayfile
    }
    relaycast_backend                             = "postgres-required-not-yet-qualified"
    hoopdb_bootstrap_profile                      = "dedicated-rds-database-review-required"
    overlapping_pipeline_workers_must_be_disabled = var.pipeline_runtime == "lambda"
  }
}

output "service_accounts" {
  description = "Distinct environment-scoped workload bindings; the application chart must use these identities."
  value = {
    namespace = local.namespace
    storage   = ["${var.release_name}-worker", "${var.release_name}-alleyoop", "${var.release_name}-session-ingest-api"]
    indexer   = local.search_indexer_sa
    reader    = local.search_reader_sa
  }
}

output "runtime_role_policy_json" {
  description = "Proposed search and Lambda runtime permissions for operator review. External mode does not attach them or validate existing IAM configuration. Values may be unknown until service resources exist."
  value = merge(
    {
      indexer  = module.search.indexer_policy_json
      reader   = module.search.reader_policy_json
      pipeline = var.pipeline_runtime == "lambda" ? module.pipeline[0].execution_role_policy_json : null
    },
    var.search_sessions_bucket_read == null ? {} : { sessions_read = module.search.sessions_read_policy_json },
  )
}

output "lambda_shared_environment" {
  description = "Non-secret writer/reader bindings, or null until explicitly configured. Independently qualify the matching reader artifact, read-only DB identity, JWT settings, schema/FGAC bootstrap and worker retirement before activation."
  value       = var.lambda_runtime_bindings == null ? null : local.lambda_shared_environment
}

output "postgres_service_bindings" {
  description = "Separate service databases and independent migration/runtime roles on the same RDS endpoint. Contains no credentials; reviewed database bootstrap, CONNECT/ACL isolation and runtime proof remain required. Optional-service bindings do not enable workloads."
  value       = module.postgres_layout.bindings
}

output "postgres_topology" {
  description = "Single-instance, separate-service-database target; application_sql_ready=false until actual service integration and managed-RDS validation are completed."
  value       = module.postgres_layout.topology
}

output "chief_execution_node" {
  description = "Chief execution host references, or null. Holds no secret value."
  value = var.chief_execution_node == null ? null : {
    instance_id             = module.chief_execution_node[0].instance_id
    role_arn                = module.chief_execution_node[0].role_arn
    security_group_id       = module.chief_execution_node[0].security_group_id
    worker_token_secret_arn = module.chief_execution_node[0].worker_token_secret_arn
  }
}

output "desktop_feed" {
  description = "Relay Control private Desktop feed bindings, or null when desktop_feed is unset. control_env maps to Control settings and extra_env is the same as the relay-control.extraEnv list; neither holds a secret."
  value = var.desktop_feed == null ? null : {
    control_env     = module.desktop_feed[0].control_env
    extra_env       = module.desktop_feed[0].control_extra_env
    key_arns        = module.desktop_feed[0].key_arns
    role_arn        = module.desktop_feed[0].role_arn
    namespace       = local.namespace
    service_account = var.desktop_feed.service_account
  }
}
