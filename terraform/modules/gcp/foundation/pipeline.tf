# This optional pull queue is distinct from the functions module's GCS
# notification/push queue. Wire it only to an application version supporting
# this native queue contract; creating infrastructure does not enable consumers.
resource "google_pubsub_topic" "pipeline" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption is used by default. Set pipeline.kms_key_name to an existing approved CMEK after granting the Pub/Sub service agent access.
  kms_key_name               = var.pipeline.kms_key_name
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  count                      = var.pipeline.enabled ? 1 : 0
  project                    = var.project_id
  name                       = "${local.prefix}-pipeline"
  message_retention_duration = var.pipeline.retention
  labels                     = local.labels
  message_storage_policy { allowed_persistence_regions = [var.region] }
  depends_on = [terraform_data.fence]
}
resource "google_pubsub_topic" "dead_letter" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption is used by default. Set pipeline.kms_key_name to an existing approved CMEK after granting the Pub/Sub service agent access.
  kms_key_name               = var.pipeline.kms_key_name
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  count                      = var.pipeline.enabled ? 1 : 0
  project                    = var.project_id
  name                       = "${local.prefix}-pipeline-dead-letter"
  message_retention_duration = var.pipeline.retention
  labels                     = local.labels
  message_storage_policy { allowed_persistence_regions = [var.region] }
  depends_on = [terraform_data.fence]
}
resource "google_pubsub_subscription" "pipeline" {
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  count                      = var.pipeline.enabled ? 1 : 0
  project                    = var.project_id
  name                       = "${local.prefix}-pipeline"
  topic                      = google_pubsub_topic.pipeline[0].id
  ack_deadline_seconds       = 600
  message_retention_duration = var.pipeline.retention
  retain_acked_messages      = false
  labels                     = local.labels
  expiration_policy { ttl = "" }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter[0].id
    max_delivery_attempts = 8
  }
}
resource "google_pubsub_subscription" "dead_letter" {
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  count                      = var.pipeline.enabled ? 1 : 0
  project                    = var.project_id
  name                       = "${local.prefix}-pipeline-dead-letter"
  topic                      = google_pubsub_topic.dead_letter[0].id
  message_retention_duration = var.pipeline.retention
  labels                     = local.labels
  expiration_policy { ttl = "" }
}
resource "google_pubsub_topic_iam_member" "publisher" {
  for_each = var.pipeline.enabled ? var.pipeline.publishers : toset([])
  project  = var.project_id
  topic    = google_pubsub_topic.pipeline[0].name
  role     = "roles/pubsub.publisher"
  member   = "${local.wi_prefix}/ns/${split("/", each.value)[0]}/sa/${split("/", each.value)[1]}"
}
resource "google_pubsub_subscription_iam_member" "subscriber" {
  for_each     = var.pipeline.enabled ? var.pipeline.subscribers : toset([])
  project      = var.project_id
  subscription = google_pubsub_subscription.pipeline[0].name
  role         = "roles/pubsub.subscriber"
  member       = "${local.wi_prefix}/ns/${split("/", each.value)[0]}/sa/${split("/", each.value)[1]}"
}
resource "google_pubsub_topic_iam_member" "dead_letter" {
  count   = var.pipeline.enabled ? 1 : 0
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${var.expected_project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
resource "google_pubsub_subscription_iam_member" "dead_letter" {
  count        = var.pipeline.enabled ? 1 : 0
  project      = var.project_id
  subscription = google_pubsub_subscription.pipeline[0].name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${var.expected_project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_redis_instance" "pipeline" {
  count                   = var.redis.enabled ? 1 : 0
  project                 = var.project_id
  name                    = "${local.prefix}-pipeline"
  region                  = var.region
  tier                    = "STANDARD_HA"
  memory_size_gb          = var.redis.memory_size_gb
  redis_version           = var.redis.version
  authorized_network      = google_compute_network.this.id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  reserved_ip_range       = google_compute_global_address.private_services.name
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  auth_enabled            = true
  deletion_protection     = var.redis.deletion_protection
  labels                  = local.labels
  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 4
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
  }
  depends_on = [google_service_networking_connection.private_services]
  # auth_string is populated into provider state even though it is not output.
  # Never use this resource when the state must contain zero service credentials.
}
