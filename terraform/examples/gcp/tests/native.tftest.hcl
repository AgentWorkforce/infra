mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
  mock_data "google_client_config" {
    defaults = { access_token = "mock-token" }
  }
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name    = "example:us-central1:agent-relay-pg"
      private_ip_address = "10.20.0.5"
      dns_names          = [{ connection_type = "PRIVATE_SERVICES_ACCESS", dns_scope = "INSTANCE", name = "agent-relay-pg.abc123.us-central1.sql-psa.goog." }]
      server_ca_cert     = [{ cert = "-----BEGIN CERTIFICATE-----", common_name = "", create_time = "", expiration_time = "", sha1_fingerprint = "" }]
    }
  }
  mock_resource "google_redis_instance" {
    defaults = {
      host            = "10.20.0.6"
      port            = 6378
      server_ca_certs = [{ cert = "-----BEGIN CERTIFICATE-----", create_time = "", expire_time = "", serial_number = "", sha1_fingerprint = "" }]
    }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  project_id           = "example"
  region               = "us-central1"
  network_self_link    = "projects/example/global/networks/agent-relay"
  sessions_bucket_name = "example-agent-relay-sessions"
}

run "native_data_services_are_complete" {
  command = apply

  assert {
    condition     = toset(module.postgres.databases) == toset(["relaycontrol", "relaycast", "hoopdb", "relayhistory"])
    error_message = "The native profile must preserve the legacy RelayHistory database during cutover."
  }
  assert {
    condition     = module.postgres.database_url_template == "postgresql://<role>:<password>@agent-relay-pg.abc123.us-central1.sql-psa.goog.:5432/<database>?sslmode=verify-full"
    error_message = "Cloud SQL URLs must use its shared-CA DNS identity and verify-full."
  }
  assert {
    condition     = one(google_dns_record_set.cloud_sql.rrdatas) == "10.20.0.5"
    error_message = "Private DNS resolves the certificate DNS name to the private Cloud SQL address."
  }
  assert {
    condition     = google_redis_instance.pipeline.tier == "STANDARD_HA" && google_redis_instance.pipeline.transit_encryption_mode == "SERVER_AUTHENTICATION" && !google_redis_instance.pipeline.auth_enabled
    error_message = "Memorystore must be HA, TLS-only and match the no-AUTH application contract."
  }
  assert {
    condition     = google_pubsub_subscription.pipeline.dead_letter_policy[0].max_delivery_attempts == 8 && google_pubsub_subscription.pipeline.deletion_policy == "PREVENT"
    error_message = "The pipeline queue needs a protected dead-letter policy."
  }
  assert {
    condition     = google_pubsub_topic_iam_member.pipeline_publisher["agent-relay-session-ingest-api"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example.svc.id.goog/subject/ns/agent-relay/sa/agent-relay-session-ingest-api"
    error_message = "Pub/Sub access must use an exact GKE Workload Identity principal."
  }
  assert {
    condition     = length(output.chart_values["sessions-pipeline"].worker.extraEnv) == 8 && output.chart_values["sessions-pipeline"].worker.extraEnv[3].value == "false"
    error_message = "The generated worker overlay must contain the complete no-AUTH TLS pipeline contract."
  }
  assert {
    condition     = output.chart_values["sessions-pipeline"].worker.migrations.runtimeRole == "sessions_pipeline_runtime" && output.chart_values["sessions-pipeline"].sessionReadApi.postgresCa.sha256 == sha256("-----BEGIN CERTIFICATE-----")
    error_message = "The generated overlay must select the native runtime role and pin the Cloud SQL CA."
  }
  assert {
    condition     = output.chart_values["sessions-pipeline"].sessionReadApi.extraEnv[3].value == "96bulls" && output.chart_values["sessions-pipeline"].sessionReadApi.extraEnv[4].value == "true"
    error_message = "The generated read API overlay must retain the GCS object-key contract when it replaces site extraEnv."
  }
}

run "image_mirror_is_off_by_default" {
  command = plan

  assert {
    condition     = length(google_artifact_registry_repository.mirror) == 0 && length(google_artifact_registry_repository_iam_member.mirror_node_reader) == 0 && output.image_mirror_root == null
    error_message = "Without image_mirror_repository the example must plan no mirror and no grant, so existing installs see no change."
  }
}

run "image_mirror_grants_the_default_node_service_account" {
  command = apply

  variables {
    image_mirror_repository = "agent-relay-mirror"
  }

  assert {
    condition     = google_artifact_registry_repository.mirror[0].repository_id == "agent-relay-mirror" && google_artifact_registry_repository.mirror[0].format == "DOCKER" && google_artifact_registry_repository.mirror[0].location == "us-central1"
    error_message = "The mirror must be a Docker repository in the install region."
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.mirror_node_reader[0].role == "roles/artifactregistry.reader" && google_artifact_registry_repository_iam_member.mirror_node_reader[0].member == "serviceAccount:123456789012-compute@developer.gserviceaccount.com"
    error_message = "Nodes on the default Compute Engine service account must get read access on the mirror only."
  }
  assert {
    condition     = output.image_mirror_root == "us-central1-docker.pkg.dev/example/agent-relay-mirror"
    error_message = "image_mirror_root must be the step 5 MIRROR_ROOT."
  }
}

run "image_mirror_grants_a_custom_node_service_account" {
  command = plan

  variables {
    image_mirror_repository  = "agent-relay-mirror"
    gke_node_service_account = "gke-nodes@example.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_artifact_registry_repository_iam_member.mirror_node_reader[0].member == "serviceAccount:gke-nodes@example.iam.gserviceaccount.com"
    error_message = "A node pool's own service account must be the one granted."
  }
}
