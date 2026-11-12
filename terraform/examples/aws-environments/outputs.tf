output "environment" {
  description = "Environment identity to compare with the separately configured backend before apply."
  value       = { name = var.environment, class = var.environment_class, account_id = var.account_id, region = var.region, namespace = local.namespace, name_prefix = var.name_prefix }
}

output "verification" {
  description = "Non-secret input for the private-runner data-path verifier. Contains secret references, never secret values. postgres is null with enable_database = false and search is null with enable_search = false."
  value = {
    environment       = var.environment
    environment_class = var.environment_class
    name_prefix       = var.name_prefix
    account_id        = var.account_id
    region            = var.region
    namespace         = local.namespace
    pippen            = var.pippen
    postgres = !var.enable_database ? null : {
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
    search = !var.enable_search ? null : {
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
  description = "Distinct environment-scoped workload bindings; the application chart must use these identities. indexer and reader are null with enable_search = false (no search Pod Identity associations exist)."
  value = {
    namespace = local.namespace
    storage   = ["${var.release_name}-worker", "${var.release_name}-alleyoop", "${var.release_name}-session-ingest-api"]
    indexer   = var.enable_search ? local.search_indexer_sa : null
    reader    = var.enable_search ? local.search_reader_sa : null
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
    local.search_sessions_bucket_read == null || !var.enable_search ? {} : { sessions_read = module.search.sessions_read_policy_json },
  )
}

output "lambda_shared_environment" {
  description = "Non-secret writer/reader bindings, or null until explicitly configured. Independently qualify the matching reader artifact, read-only DB identity, JWT settings, schema/FGAC bootstrap and worker retirement before activation."
  value       = var.lambda_runtime_bindings == null ? null : local.lambda_shared_environment
}

output "postgres_service_bindings" {
  description = "Separate service databases and independent migration/runtime roles on the same RDS endpoint. Contains no credentials; reviewed database bootstrap, CONNECT/ACL isolation and runtime proof remain required. Optional-service bindings do not enable workloads. null with enable_database = false."
  value       = var.enable_database ? module.postgres_layout[0].bindings : null
}

output "postgres_topology" {
  description = "Single-instance, separate-service-database target; application_sql_ready=false until actual service integration and managed-RDS validation are completed. null with enable_database = false."
  value       = var.enable_database ? module.postgres_layout[0].topology : null
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

output "history_upload" {
  description = "Direct upload wiring only; enablement needs compatible published Control/consumer images and the same witness Secret provisioned out of band. No secret values in Terraform."
  value = local.history_upload_enabled ? merge({
    control_role_arn         = local.history_control_role_arn
    consumer_role_arn        = aws_iam_role.history_consumer[0].arn
    control_service_account  = var.history_upload.control_service_account
    consumer_service_account = var.history_upload.consumer_service_account
    control_values = {
      historyUpload = {
        mode      = "off"
        bucket    = module.sessions_bucket.bucket_name
        region    = var.region
        keyRoot   = var.history_upload.key_root
        roleArn   = module.sessions_bucket.history_upload_role_arn
        kmsKeyArn = var.kms_key_arn
      }
    }
    }, local.unmanaged_policy ? {
    # The unmanaged bucket policy must carry these (the plan refuses otherwise).
    bucket_policy_statements_to_merge = module.sessions_bucket.bucket_policy_statements
  } : {}) : null
}
