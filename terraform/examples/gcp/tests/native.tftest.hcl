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
  mock_resource "google_service_account" {
    defaults = {
      email = "agent-relay-control@example.iam.gserviceaccount.com"
      name  = "projects/example/serviceAccounts/agent-relay-control@example.iam.gserviceaccount.com"
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

run "desktop_feed_is_off_by_default" {
  command = plan

  assert {
    condition     = length(module.desktop_feed_bucket) == 0 && length(google_service_account_iam_member.desktop_feed_sign_self) == 0 && output.desktop_feed == null && !contains(keys(output.chart_values["relay-control"]), "extraEnv")
    error_message = "The Desktop feed bucket must be opt-in so existing installs plan no change."
  }
}

run "desktop_feed_bucket_and_identity" {
  command = apply

  variables {
    desktop_feed_bucket_name = "example-agent-relay-desktop-feed"
  }

  assert {
    condition     = module.desktop_feed_bucket[0].bucket_name == "example-agent-relay-desktop-feed"
    error_message = "The feed bucket must use the requested name."
  }
  assert {
    condition     = google_service_account_iam_member.desktop_feed_sign_self[0].role == "roles/iam.serviceAccountTokenCreator" && google_service_account_iam_member.desktop_feed_sign_self[0].member == "serviceAccount:${output.desktop_feed.service_account}"
    error_message = "relay-control's service account must be able to signBlob as itself for signed download URLs."
  }
  assert {
    condition     = output.desktop_feed.service_account_annotations["iam.gke.io/return-principal-id-as-email"] == "true" && output.desktop_feed.env[0].value == "gcs"
    error_message = "The output must carry both Workload Identity annotations and the gcs storage setting."
  }
  assert {
    condition     = output.chart_values["relay-control"].serviceAccount.annotations["iam.gke.io/gcp-service-account"] == output.desktop_feed.service_account && length(output.chart_values["relay-control"].extraEnv) == 3
    error_message = "managed-values.json must carry the feed env and KSA annotations for relay-control."
  }
  assert {
    condition     = module.desktop_feed_bucket[0].google_service_account_email != null && contains(keys(output.chart_values["relay-control"]), "postgresCa")
    error_message = "Enabling the feed must keep relay-control's Cloud SQL CA values."
  }
}

run "cmek_is_off_by_default" {
  command = apply

  assert {
    condition     = google_redis_instance.pipeline.customer_managed_key == null && google_pubsub_topic.pipeline.kms_key_name == null
    error_message = "Without key inputs every service uses Google-managed encryption."
  }
}

# The regulated profile (regulated.tfvars.example): every key input reaches its resource.
run "regulated_profile_wires_every_key" {
  command = apply
  variables {
    kms_key_name                 = "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    pipeline_pubsub_kms_key_name = "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    pipeline_redis_kms_key_name  = "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    admin_secret_kms_key_name    = "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    image_mirror_kms_key_name    = "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    image_mirror_repository      = "agent-relay-mirror"
    desktop_feed_bucket_name     = "example-agent-relay-desktop-feed"
  }

  # Cloud SQL, its admin-password secret and the buckets take the key inside
  # their modules (main.tf passes kms_key_name and admin_user); the modules'
  # own tests assert the resources. Module internals are not addressable here.
  assert {
    condition     = google_pubsub_topic.pipeline.kms_key_name == "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data" && google_pubsub_topic.pipeline_dead_letter.kms_key_name == "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    error_message = "Both Pub/Sub topics must use the key."
  }
  assert {
    condition     = google_redis_instance.pipeline.customer_managed_key == "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    error_message = "Redis must use the key."
  }
  assert {
    condition     = google_artifact_registry_repository.mirror[0].kms_key_name == "projects/example/locations/us-central1/keyRings/relay/cryptoKeys/data"
    error_message = "The image mirror must use the key."
  }
}

run "edge_tls_policy_is_on_by_default" {
  command = apply

  assert {
    condition     = output.chart_values.gkeIngress.sslPolicy == "agent-relay-tls" && output.edge.ssl_policy == "agent-relay-tls"
    error_message = "managed-values.json must name the TLS 1.2 SSL policy for the GKE Ingress."
  }
  assert {
    condition     = output.edge.security_policy == null && output.edge.client_ip_header == null
    error_message = "Cloud Armor is off by default."
  }
}

run "edge_tls_policy_opt_out" {
  command = apply
  variables {
    edge_ssl_policy = { create = false }
  }

  assert {
    condition     = output.chart_values.gkeIngress.sslPolicy == "" && output.edge.ssl_policy == null
    error_message = "Opting out must leave the chart default (no sslPolicy)."
  }
}

run "edge_cloud_armor_behind_cloudflare" {
  command = apply
  variables {
    edge_security_policy      = { create = true, cloudflare = { enabled = true } }
    edge_origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }

  assert {
    condition     = output.edge.security_policy == "agent-relay-edge" && output.edge.client_ip_header == "CF-Connecting-IP"
    error_message = "The Cloud Armor policy and the client-address header must be reported."
  }
  # Default of 10 subexpressions: secret header, two WAF rules, and two sign-in
  # throttles for Cloudflare's 15 ranges (nine per rule).
  assert {
    condition     = output.edge.rule_counts.advanced == 5 && output.edge.rule_counts.total == 8
    error_message = "Behind Cloudflare the default policy needs 5 advanced rules and 8 in all."
  }
}

run "edge_rule_counts_are_reported" {
  command = apply
  variables {
    edge_security_policy = { create = true }
  }

  # Two WAF rules and the sign-in throttle have expressions; the default rule is basic.
  assert {
    condition     = output.edge.rule_counts.advanced == 3 && output.edge.rule_counts.total == 4
    error_message = "The default Cloud Armor policy needs 3 advanced rules and 4 rules in all."
  }
}
