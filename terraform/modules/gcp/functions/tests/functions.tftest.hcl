mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
  mock_data "google_storage_project_service_account" {
    defaults = { email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email  = "relay-pipeline@proj.iam.gserviceaccount.com"
      member = "serviceAccount:relay-pipeline@proj.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_secret_manager_secret" {
    defaults = { id = "projects/proj/secrets/relay-session-pipeline" }
  }
  mock_resource "google_pubsub_topic" {
    defaults = { id = "projects/proj/topics/relay-session-events" }
  }
  mock_resource "google_cloudfunctions2_function" {
    defaults = {
      service_config = { uri = "https://relay-session-pipeline-abc-uc.a.run.app" }
    }
  }
}

variables {
  project_id     = "proj"
  region         = "us-central1"
  name           = "relay"
  bucket_name    = "relay-sessions"
  source_archive = { bucket = "relay-artifacts", object = "session-pipeline.zip" }
}

run "defaults_are_internal_and_authenticated" {
  command = apply

  # A distinct invoker identity, so the OIDC and invoker asserts can tell the
  # two service accounts apart.
  override_resource {
    target = google_service_account.invoker
    values = {
      email  = "invoker@proj.iam.gserviceaccount.com"
      member = "serviceAccount:invoker@proj.iam.gserviceaccount.com"
    }
  }

  assert {
    condition     = google_cloudfunctions2_function.this.service_config[0].ingress_settings == "ALLOW_INTERNAL_ONLY"
    error_message = "The function is internal-only."
  }
  assert {
    condition     = google_cloud_run_v2_service_iam_member.invoker.member == "serviceAccount:invoker@proj.iam.gserviceaccount.com"
    error_message = "Only the invoker service account may invoke the function."
  }
  assert {
    condition     = google_pubsub_subscription.push.push_config[0].oidc_token[0].service_account_email == "invoker@proj.iam.gserviceaccount.com"
    error_message = "Push deliveries are OIDC-authenticated."
  }
  assert {
    condition     = google_pubsub_subscription.push.dead_letter_policy[0].max_delivery_attempts == 8
    error_message = "Dead-letter after 8 attempts."
  }
  assert {
    condition     = google_storage_notification.manifests.object_name_prefix == "96bulls/" && toset(google_storage_notification.manifests.event_types) == toset(["OBJECT_FINALIZE", "OBJECT_DELETE", "OBJECT_ARCHIVE"])
    error_message = "Object finalize and delete under the tenant prefix are notified."
  }
  assert {
    condition     = google_cloud_scheduler_job.reconcile.schedule == "*/30 * * * *" && google_cloud_scheduler_job.brief.paused
    error_message = "Reconcile every 30 minutes; briefs paused by default."
  }
  assert {
    condition     = google_storage_bucket_iam_member.function_reads.role == "roles/storage.objectViewer"
    error_message = "The function only reads objects."
  }
  assert {
    condition     = google_cloudfunctions2_function.this.service_config[0].environment_variables.PIPELINE_RECONCILE_LOOKBACK_MINUTES == "60"
    error_message = "Lookback is twice the reconcile cadence."
  }
}

run "hourly_reconcile_cron" {
  command = plan

  variables {
    reconcile_minutes = 120
    briefs_enabled    = true
  }

  assert {
    condition     = google_cloud_scheduler_job.reconcile.schedule == "0 */2 * * *" && !google_cloud_scheduler_job.brief.paused
    error_message = "120 minutes is every two hours; briefs_enabled unpauses the brief job."
  }
}

run "cmek_needs_repository" {
  command = plan

  variables {
    kms_key_name = "projects/proj/locations/us-central1/keyRings/r/cryptoKeys/k"
  }

  expect_failures = [google_cloudfunctions2_function.this]
}

run "long_names_get_distinct_service_accounts" {
  command = plan

  variables {
    name = "abcdefghijklmnopqrstuvwxyz123"
  }

  assert {
    condition     = google_service_account.function.account_id != google_service_account.invoker.account_id && length(google_service_account.invoker.account_id) <= 30 && length(google_service_account.function.account_id) <= 30
    error_message = "Service account IDs stay distinct and within 30 characters."
  }
}

run "timeout_cannot_exceed_ack_deadline" {
  command = plan

  variables {
    timeout_seconds      = 600
    ack_deadline_seconds = 300
  }

  expect_failures = [google_cloudfunctions2_function.this]
}

run "malformed_dead_letter_retention" {
  command = plan

  variables {
    dead_letter_retention = "10m"
  }

  expect_failures = [var.dead_letter_retention]
}
