output "chart_values" {
  description = "Non-secret agent-relay chart values (values-gcp.yaml) these resources feed. Database URLs go in the release Secret, not here; see terraform/README.md."
  value = {
    "sessions-pipeline.worker.locker.bucket"             = module.sessions_bucket.bucket_name
    "sessions-pipeline.worker.locker.region"             = module.sessions_bucket.region
    "sessions-pipeline.ingestEdge.locker.bucket"         = module.sessions_bucket.bucket_name
    "sessions-pipeline.ingestEdge.locker.region"         = module.sessions_bucket.region
    "sessions-pipeline.searchIndexer.locker.bucket"      = module.sessions_bucket.bucket_name
    "sessions-pipeline.searchIndexer.locker.region"      = module.sessions_bucket.region
    "sessions-pipeline.worker.CLOUD_SQL_CONNECTION_NAME" = module.postgres.connection_name
    "sessions-pipeline.worker.REDIS_HOST"                = google_redis_instance.pipeline.host
    "sessions-pipeline.worker.REDIS_PORT"                = tostring(google_redis_instance.pipeline.port)
    "sessions-pipeline.worker.PUBSUB_TOPIC"              = google_pubsub_topic.pipeline.id
    "sessions-pipeline.worker.PUBSUB_SUBSCRIPTION"       = google_pubsub_subscription.pipeline.id
  }
}

output "postgres" {
  description = "Cloud SQL private IP, admin secret and URL template. connection_name feeds CLOUD_SQL_CONNECTION_NAME in the sessions worker and alleyoop extraEnv."
  value = {
    private_ip_address       = module.postgres.private_ip_address
    dns_name                 = module.postgres.dns_name
    connection_name          = module.postgres.connection_name
    admin_username           = module.postgres.admin_username
    admin_password_secret_id = module.postgres.admin_password_secret_id
    database_url_template    = module.postgres.database_url_template
    server_ca_cert           = module.postgres.server_ca_cert
  }
}

output "pipeline" {
  description = "Native Sessions pipeline values. The Redis CA is public certificate material, not a credential."
  value = {
    pubsub_topic_id        = google_pubsub_topic.pipeline.id
    pubsub_subscription_id = google_pubsub_subscription.pipeline.id
    redis_host             = google_redis_instance.pipeline.host
    redis_port             = google_redis_instance.pipeline.port
    redis_tls_ca_pem       = nonsensitive(google_redis_instance.pipeline.server_ca_certs[0].cert)
    redis_tls_required     = true
    redis_auth_enabled     = false
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
