# Native Sessions data path. These resources are required when
# values-gcp-native.yaml uses the GCS Locker provider.

locals {
  workload_identity_prefix = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa"
  pipeline_publishers = toset([
    "${var.release_name}-worker",
    "${var.release_name}-session-ingest-api",
  ])
  pipeline_subscribers = toset([
    "${var.release_name}-worker",
    "${var.release_name}-search-indexer",
  ])
}

resource "google_pubsub_topic" "pipeline" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption is the default; set pipeline_pubsub_kms_key_name for CMEK.
  project                    = var.project_id
  name                       = "${var.name}-pipeline"
  kms_key_name               = var.pipeline_pubsub_kms_key_name
  message_retention_duration = var.pipeline_message_retention
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  labels                     = var.labels

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }
}

resource "google_pubsub_topic" "pipeline_dead_letter" {
  #checkov:skip=CKV_GCP_83:Google-managed encryption is the default; set pipeline_pubsub_kms_key_name for CMEK.
  project                    = var.project_id
  name                       = "${var.name}-pipeline-dead-letter"
  kms_key_name               = var.pipeline_pubsub_kms_key_name
  message_retention_duration = var.pipeline_message_retention
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  labels                     = var.labels

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }
}

resource "google_pubsub_subscription" "pipeline" {
  project                    = var.project_id
  name                       = "${var.name}-pipeline"
  topic                      = google_pubsub_topic.pipeline.id
  ack_deadline_seconds       = 600
  message_retention_duration = var.pipeline_message_retention
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  retain_acked_messages      = false
  labels                     = var.labels

  expiration_policy { ttl = "" }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.pipeline_dead_letter.id
    max_delivery_attempts = 8
  }
}

resource "google_pubsub_subscription" "pipeline_dead_letter" {
  project                    = var.project_id
  name                       = "${var.name}-pipeline-dead-letter"
  topic                      = google_pubsub_topic.pipeline_dead_letter.id
  message_retention_duration = var.pipeline_message_retention
  deletion_policy            = var.deletion_protection ? "PREVENT" : "DELETE"
  labels                     = var.labels

  expiration_policy { ttl = "" }
}

resource "google_pubsub_topic_iam_member" "pipeline_publisher" {
  for_each = local.pipeline_publishers
  project  = var.project_id
  topic    = google_pubsub_topic.pipeline.name
  role     = "roles/pubsub.publisher"
  member   = "${local.workload_identity_prefix}/${each.value}"
}

resource "google_pubsub_subscription_iam_member" "pipeline_subscriber" {
  for_each     = local.pipeline_subscribers
  project      = var.project_id
  subscription = google_pubsub_subscription.pipeline.name
  role         = "roles/pubsub.subscriber"
  member       = "${local.workload_identity_prefix}/${each.value}"
}

resource "google_pubsub_topic_iam_member" "pubsub_dead_letter" {
  project = var.project_id
  topic   = google_pubsub_topic.pipeline_dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "pubsub_dead_letter" {
  project      = var.project_id
  subscription = google_pubsub_subscription.pipeline.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_redis_instance" "pipeline" {
  project                 = var.project_id
  name                    = "${var.name}-pipeline"
  region                  = var.region
  tier                    = "STANDARD_HA"
  memory_size_gb          = var.pipeline_redis_memory_size_gb
  redis_version           = var.pipeline_redis_version
  authorized_network      = var.network_self_link
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  reserved_ip_range       = var.pipeline_redis_reserved_ip_range
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  auth_enabled            = false
  deletion_protection     = var.deletion_protection
  labels                  = var.labels

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
}
