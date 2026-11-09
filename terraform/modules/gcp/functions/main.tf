data "google_project" "this" {
  project_id = var.project_id
}

data "google_storage_project_service_account" "this" {
  project = var.project_id
}

locals {
  # Service account IDs are at most 30 characters: truncate the shared prefix
  # before the distinct suffixes so long names cannot collide.
  sa_prefix        = trimsuffix(substr(var.name, 0, 21), "-")
  function_name    = "${var.name}-session-pipeline"
  topic_name       = "${var.name}-session-events"
  dlq_name         = "${var.name}-session-events-dlq"
  key_prefix       = trim(var.key_prefix, "/")
  pubsub_agent     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  scheduler_region = coalesce(var.scheduler_region, var.region)
  secret_id        = var.create_secret ? google_secret_manager_secret.pipeline[0].id : var.secret_id
  function_uri     = google_cloudfunctions2_function.this.service_config[0].uri

  reconcile_cron = var.reconcile_minutes < 60 ? "*/${var.reconcile_minutes} * * * *" : "0 */${floor(var.reconcile_minutes / 60)} * * *"

  environment = merge({
    PIPELINE_RAW_GCS_BUCKET             = var.bucket_name
    PIPELINE_KEY_PREFIX                 = local.key_prefix
    PIPELINE_ORG_FROM_PREFIX            = "true"
    SESSION_PIPELINE_SECRET_ID          = local.secret_id
    SESSION_PIPELINE_TOPIC              = google_pubsub_topic.events.id
    SEARCH_INDEX_ENABLED                = var.search_index_enabled ? "1" : "0"
    PIPELINE_FANOUT                     = "off"
    PIPELINE_RECONCILE_LOOKBACK_MINUTES = tostring(2 * var.reconcile_minutes)
    HOOPDB_POOL_MAX                     = "4"
    OTEL_SERVICE_NAME                   = "96bulls-session-pipeline"
    SESSION_BRIEF_ENABLED               = var.briefs_enabled ? "true" : "false"
  }, var.environment)
}

# ---------------------------------------------------------------------------
# Identities
# ---------------------------------------------------------------------------

resource "google_service_account" "function" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-pipeline"
  display_name = "agent-relay session pipeline function"
}

resource "google_service_account" "invoker" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-invoker"
  display_name = "agent-relay session pipeline invoker (Pub/Sub push, Cloud Scheduler)"
}

# Read session objects (list + get). objectViewer is the narrowest predefined
# role with list, which the services need to tell a delete from a denial.
resource "google_storage_bucket_iam_member" "function_reads" {
  bucket = var.bucket_name
  role   = "roles/storage.objectViewer"
  member = google_service_account.function.member
}

# The reconcile re-enqueues recent manifests and publishes its own
# continuation.
resource "google_pubsub_topic_iam_member" "function_publishes" {
  project = var.project_id
  topic   = google_pubsub_topic.events.name
  role    = "roles/pubsub.publisher"
  member  = google_service_account.function.member
}

resource "google_secret_manager_secret_iam_member" "function_reads_secret" {
  project   = var.project_id
  secret_id = local.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.function.member
}

# Only the invoker (push subscription, scheduler jobs) may call the function.
# A reconcile that reaches its deadline continues by publishing
# {"reconcile": true, "cursor": ...} to the events topic, not by an HTTP
# self-call, which internal-only ingress would refuse without a VPC route.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.this.name
  role     = "roles/run.invoker"
  member   = google_service_account.invoker.member
}

# ---------------------------------------------------------------------------
# Secret (a container; the value is added out of band and never in state)
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret" "pipeline" {
  count = var.create_secret ? 1 : 0

  project   = var.project_id
  secret_id = "${var.name}-session-pipeline"
  labels    = var.labels

  replication {
    auto {
      dynamic "customer_managed_encryption" {
        for_each = var.secret_kms_key_name == null ? [] : [1]
        content {
          kms_key_name = var.secret_kms_key_name
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Topics, notification, subscriptions
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "events" {
  project      = var.project_id
  name         = local.topic_name
  kms_key_name = var.topic_kms_key_name
  labels       = var.labels
}

resource "google_pubsub_topic" "dlq" {
  project                    = var.project_id
  name                       = local.dlq_name
  kms_key_name               = var.topic_kms_key_name
  message_retention_duration = var.dead_letter_retention
  labels                     = var.labels
}

resource "google_pubsub_topic_iam_member" "gcs_publishes" {
  project = var.project_id
  topic   = google_pubsub_topic.events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.this.email_address}"
}

resource "google_storage_notification" "manifests" {
  bucket         = var.bucket_name
  topic          = google_pubsub_topic.events.id
  payload_format = "JSON_API_V1"
  # On a versioned bucket, deleting the live manifest archives it
  # (OBJECT_ARCHIVE) instead of deleting it; an overwrite also archives the
  # previous generation. The handler must check whether a live manifest exists.
  event_types        = ["OBJECT_FINALIZE", "OBJECT_DELETE", "OBJECT_ARCHIVE"]
  object_name_prefix = "${local.key_prefix}/"

  depends_on = [google_pubsub_topic_iam_member.gcs_publishes]
}

resource "google_pubsub_subscription" "push" {
  project                    = var.project_id
  name                       = "${local.topic_name}-push"
  topic                      = google_pubsub_topic.events.id
  ack_deadline_seconds       = var.ack_deadline_seconds
  message_retention_duration = "345600s"
  labels                     = var.labels

  push_config {
    push_endpoint = local.function_uri
    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = local.function_uri
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker]
}

# Dead-lettered messages are kept here for inspection and replay.
resource "google_pubsub_subscription" "dlq" {
  project                    = var.project_id
  name                       = "${local.dlq_name}-hold"
  topic                      = google_pubsub_topic.dlq.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.dead_letter_retention
  retain_acked_messages      = false
  labels                     = var.labels

  expiration_policy {
    ttl = ""
  }
}

# The Pub/Sub service agent forwards to the dead-letter topic and acks the
# original, so it needs publisher there and subscriber on the source.
resource "google_pubsub_topic_iam_member" "pubsub_dead_letters" {
  project = var.project_id
  topic   = google_pubsub_topic.dlq.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "pubsub_dead_letters" {
  project      = var.project_id
  subscription = google_pubsub_subscription.push.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# ---------------------------------------------------------------------------
# Function
# ---------------------------------------------------------------------------

resource "google_cloudfunctions2_function" "this" {
  project      = var.project_id
  location     = var.region
  name         = local.function_name
  description  = "agent-relay session pipeline (event-driven mode)"
  kms_key_name = var.kms_key_name
  labels       = var.labels

  build_config {
    runtime           = var.runtime
    entry_point       = var.entry_point
    docker_repository = var.docker_repository
    service_account   = var.build_service_account
    source {
      storage_source {
        bucket     = var.source_archive.bucket
        object     = var.source_archive.object
        generation = var.source_archive.generation
      }
    }
  }

  service_config {
    min_instance_count               = 0
    max_instance_count               = var.max_instance_count
    max_instance_request_concurrency = var.max_instance_request_concurrency
    available_memory                 = var.available_memory
    available_cpu                    = var.available_cpu
    timeout_seconds                  = var.timeout_seconds
    environment_variables            = local.environment
    service_account_email            = google_service_account.function.email
    # Pub/Sub push and Cloud Scheduler in the same project count as internal.
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true
    vpc_connector                  = var.vpc_connector
    vpc_connector_egress_settings  = var.vpc_connector == null ? null : var.vpc_connector_egress_settings
  }

  lifecycle {
    precondition {
      condition     = var.create_secret || var.secret_id != null
      error_message = "Set secret_id when create_secret is false."
    }
    precondition {
      condition     = var.timeout_seconds <= var.ack_deadline_seconds
      error_message = "timeout_seconds must not exceed ack_deadline_seconds, or Pub/Sub redelivers a message still being processed."
    }
    precondition {
      condition     = var.kms_key_name == null || var.docker_repository != null
      error_message = "kms_key_name needs a CMEK-encrypted docker_repository."
    }
  }
}

# ---------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------

resource "google_cloud_scheduler_job" "reconcile" {
  project     = var.project_id
  region      = local.scheduler_region
  name        = "${var.name}-session-reconcile"
  description = "agent-relay session pipeline: reconcile recent manifests (lost notifications)"
  schedule    = local.reconcile_cron
  time_zone   = var.time_zone

  http_target {
    http_method = "POST"
    uri         = local.function_uri
    body        = base64encode(jsonencode({ reconcile = true }))
    headers     = { "Content-Type" = "application/json" }
    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = local.function_uri
    }
  }

  retry_config {
    retry_count = 1
  }
}

resource "google_cloud_scheduler_job" "brief" {
  project     = var.project_id
  region      = local.scheduler_region
  name        = "${var.name}-session-brief"
  description = "agent-relay session pipeline: one session-brief tick (due wakeups)"
  schedule    = var.brief_schedule
  time_zone   = var.time_zone
  paused      = !var.briefs_enabled

  http_target {
    http_method = "POST"
    uri         = local.function_uri
    body        = base64encode(jsonencode({ brief = true }))
    headers     = { "Content-Type" = "application/json" }
    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = local.function_uri
    }
  }
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "dead_letters" {
  count = var.create_alerts ? 1 : 0

  project               = var.project_id
  display_name          = "${local.dlq_name} not empty"
  combiner              = "OR"
  notification_channels = var.notification_channels
  user_labels           = var.labels

  documentation {
    content = "Session pipeline messages exhausted their delivery attempts. Inspect ${google_pubsub_subscription.dlq.name} and republish to ${google_pubsub_topic.events.name}."
  }

  conditions {
    display_name = "dead-lettered messages"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${google_pubsub_subscription.dlq.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "backlog_age" {
  count = var.create_alerts ? 1 : 0

  project               = var.project_id
  display_name          = "${local.topic_name} backlog age"
  combiner              = "OR"
  notification_channels = var.notification_channels
  user_labels           = var.labels

  documentation {
    content = "The oldest unacked session event is older than 15 minutes: the pipeline is behind or failing."
  }

  conditions {
    display_name = "oldest unacked message age > 15 min"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${google_pubsub_subscription.push.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      comparison      = "COMPARISON_GT"
      threshold_value = 900
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "errors" {
  count = var.create_alerts ? 1 : 0

  project               = var.project_id
  display_name          = "${local.function_name} errors"
  combiner              = "OR"
  notification_channels = var.notification_channels
  user_labels           = var.labels

  documentation {
    content = "Session pipeline requests are failing (non-2xx responses: init errors, timeouts, crashes)."
  }

  conditions {
    display_name = "non-2xx responses"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${google_cloudfunctions2_function.this.name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class != \"2xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "900s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
}
