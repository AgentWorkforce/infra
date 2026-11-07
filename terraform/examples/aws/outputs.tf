output "chart_values" {
  description = "Non-secret agent-relay chart values (values-eks.yaml) these resources feed. Database URLs go in the release Secret, not here; see terraform/README.md."
  value = {
    "sessions-pipeline.worker.locker.bucket"   = module.sessions_bucket.bucket_name
    "sessions-pipeline.worker.locker.region"   = module.sessions_bucket.bucket_region
    "sessions-pipeline.alleyoop.locker.bucket" = module.sessions_bucket.bucket_name
    "sessions-pipeline.alleyoop.locker.region" = module.sessions_bucket.bucket_region
  }
}

output "postgres" {
  description = "Postgres host, port, master secret and URL template."
  value = {
    host                   = module.postgres.host
    port                   = module.postgres.port
    master_user_secret_arn = module.postgres.master_user_secret_arn
    database_url_template  = module.postgres.database_url_template
  }
}

output "sessions_role_arn" {
  description = "Pod Identity role for the worker and alleyoop ServiceAccounts."
  value       = module.sessions_bucket.access_role_arn
}

output "search" {
  description = "OpenSearch endpoint and the roles to map as backend_roles with the master user: indexer_role_arn and lambda_indexer_role_arn (event mode) to the write role, reader_role_arn to the read-only role (null unless enable_search)."
  value = var.enable_search ? {
    url              = module.search[0].url
    indexer_role_arn = module.search[0].indexer_role_arn
    reader_role_arn  = module.search[0].reader_role_arn
    # In event mode the pipeline Lambda writes the index too: map its role to
    # the same OpenSearch write role as indexer_role_arn.
    lambda_indexer_role_arn = var.enable_functions ? module.functions[0].execution_role_arn : null
  } : null
}

output "functions" {
  description = "Pipeline function, queue, DLQ and secret (null unless enable_functions)."
  value = var.enable_functions ? {
    function_name = module.functions[0].function_name
    queue_url     = module.functions[0].queue_url
    dlq_url       = module.functions[0].dlq_url
    secret_arn    = module.functions[0].secret_arn
  } : null
}

output "postgres_service_bindings" {
  description = "Target per-service schemas and independent migration/runtime roles on the SAME RDS/database. Contains no credentials; schema-aware runtime/bootstrap and isolation proof remain required. Optional-service bindings do not enable those workloads."
  value       = module.postgres_layout.bindings
}

output "postgres_topology" {
  description = "Shared-database relational target; application_sql_ready=false until actual service integration and managed-RDS validation are completed."
  value       = module.postgres_layout.topology
}
