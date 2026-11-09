output "chart_values" {
  description = "Non-secret agent-relay chart values (values-gcp.yaml) these resources feed. Database URLs go in the release Secret, not here; see terraform/README.md."
  value = {
    "sessions-pipeline.worker.locker.bucket"   = module.sessions_bucket.bucket_name
    "sessions-pipeline.worker.locker.region"   = module.sessions_bucket.region
    "sessions-pipeline.alleyoop.locker.bucket" = module.sessions_bucket.bucket_name
    "sessions-pipeline.alleyoop.locker.region" = module.sessions_bucket.region
  }
}

output "postgres" {
  description = "Cloud SQL private IP, admin secret and URL template. connection_name feeds CLOUD_SQL_CONNECTION_NAME in the sessions worker and alleyoop extraEnv."
  value = {
    private_ip_address       = module.postgres.private_ip_address
    connection_name          = module.postgres.connection_name
    admin_username           = module.postgres.admin_username
    admin_password_secret_id = module.postgres.admin_password_secret_id
    database_url_template    = module.postgres.database_url_template
  }
}

output "search_url" {
  description = "In-cluster OpenSearch URL (null unless enable_search)."
  value       = var.enable_search ? module.search[0].url : null
}

output "functions" {
  description = "Pipeline function, topics and secret (null unless enable_functions)."
  value = var.enable_functions ? {
    function_name        = module.functions[0].function_name
    events_topic_id      = module.functions[0].events_topic_id
    dead_letter_topic_id = module.functions[0].dead_letter_topic_id
    secret_id            = module.functions[0].secret_id
  } : null
}
