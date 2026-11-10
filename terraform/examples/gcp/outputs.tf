locals {
  cloud_sql_ca_sha256 = sha256(module.postgres.server_ca_cert)
  pipeline_extra_env = [
    { name = "CLOUD_SQL_CONNECTION_NAME", value = module.postgres.connection_name },
    { name = "REDIS_HOST", value = google_redis_instance.pipeline.host },
    { name = "REDIS_PORT", value = tostring(google_redis_instance.pipeline.port) },
    { name = "REDIS_AUTH_ENABLED", value = "false" },
    { name = "REDIS_TRANSIT_ENCRYPTION", value = "SERVER_AUTHENTICATION" },
    { name = "REDIS_TLS_CA_PEM", value = nonsensitive(google_redis_instance.pipeline.server_ca_certs[0].cert) },
    { name = "PUBSUB_TOPIC", value = google_pubsub_topic.pipeline.id },
    { name = "PUBSUB_SUBSCRIPTION", value = google_pubsub_subscription.pipeline.id },
  ]
  postgres_ca = {
    enabled   = true
    configMap = "cloud-sql-ca"
    key       = "ca.crt"
    sha256    = local.cloud_sql_ca_sha256
  }
}

output "chart_values" {
  description = "Complete non-secret managed-service overlay for values-gcp.yaml plus values-gcp-native.yaml. Save with: terraform output -json chart_values > managed-values.json."
  value = {
    "sessions-pipeline" = {
      worker = {
        locker = {
          bucket = module.sessions_bucket.bucket_name
          region = module.sessions_bucket.region
        }
        migrations = {
          runtimeRole      = "sessions_pipeline_runtime"
          runtimeRoleLogin = true
        }
        postgresCa = local.postgres_ca
        extraEnv   = local.pipeline_extra_env
      }
      alleyoop = {
        postgresCa = local.postgres_ca
        extraEnv   = local.pipeline_extra_env
      }
      sessionReadApi = {
        postgres   = { tlsProfile = "custom-ca" }
        postgresCa = local.postgres_ca
        extraEnv = [
          { name = "LOCKER_PROVIDER", value = "gcs" },
          { name = "LOCKER_BUCKET", value = module.sessions_bucket.bucket_name },
          { name = "LOCKER_REGION", value = module.sessions_bucket.region },
          { name = "PIPELINE_KEY_PREFIX", value = "96bulls" },
          { name = "PIPELINE_ORG_FROM_PREFIX", value = "true" },
        ]
      }
      ingestEdge = {
        locker = {
          provider = "gcs"
          bucket   = module.sessions_bucket.bucket_name
          region   = module.sessions_bucket.region
        }
        postgres = {
          caConfigMap = "cloud-sql-ca"
          caKey       = "ca.crt"
          caSha256    = local.cloud_sql_ca_sha256
        }
      }
      searchIndexer = {
        locker = {
          provider = "gcs"
          bucket   = module.sessions_bucket.bucket_name
          region   = module.sessions_bucket.region
        }
        postgres = {
          tlsProfile  = "custom-ca"
          caConfigMap = "cloud-sql-ca"
          caKey       = "ca.crt"
          caSha256    = local.cloud_sql_ca_sha256
        }
        extraEnv = local.pipeline_extra_env
      }
    }
    "relay-control" = {
      postgresCa = {
        enabled   = true
        configMap = "cloud-sql-ca"
        key       = "ca.crt"
      }
    }
    relaycast = {
      postgresCa = {
        enabled   = true
        configMap = "cloud-sql-ca"
        key       = "ca.crt"
      }
    }
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
