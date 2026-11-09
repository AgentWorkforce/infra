mock_provider "google" {
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name    = "proj:us-central1:relay"
      private_ip_address = "10.10.0.5"
      server_ca_cert     = [{ cert = "-----BEGIN CERTIFICATE-----", common_name = "", create_time = "", expiration_time = "", sha1_fingerprint = "" }]
    }
  }
  mock_resource "google_secret_manager_secret" {
    defaults = { id = "projects/proj/secrets/relay-admin-password" }
  }
}

# random is the real provider: it is local, needs no credentials, and mock
# providers do not support ephemeral resources before Terraform 1.17.

variables {
  project_id        = "proj"
  region            = "us-central1"
  name              = "relay"
  network_self_link = "projects/proj/global/networks/vpc"
  databases         = ["relaycontrol", "relayhistory", "hoopdb"]
}

run "defaults_are_private_and_protected" {
  command = apply

  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ipv4_enabled == false
    error_message = "No public IP."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "TLS is required."
  }
  assert {
    condition     = google_sql_database_instance.this.deletion_protection && google_sql_database_instance.this.settings[0].deletion_protection_enabled
    error_message = "Deletion protection on both sides."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].enabled && google_sql_database_instance.this.settings[0].backup_configuration[0].point_in_time_recovery_enabled
    error_message = "Backups and PITR on."
  }
  assert {
    condition     = google_sql_database_instance.this.database_version == "POSTGRES_17" && google_sql_database_instance.this.settings[0].availability_type == "REGIONAL"
    error_message = "PostgreSQL 17, regional HA by default."
  }
  assert {
    condition     = google_sql_user.admin[0].password == null
    error_message = "The admin password must only be passed write-only."
  }
  assert {
    condition     = google_secret_manager_secret_version.admin[0].secret_data == null
    error_message = "The secret version must only be written write-only."
  }
  assert {
    condition     = length(google_sql_database.this) == 3
    error_message = "Requested databases are created."
  }
  assert {
    condition = alltrue([
      for f in ["log_checkpoints", "log_connections", "log_disconnections", "log_lock_waits", "cloudsql.iam_authentication"] :
      contains([for x in google_sql_database_instance.this.settings[0].database_flags : x.name if x.value == "on"], f)
    ])
    error_message = "Logging flags and IAM authentication are on by default."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].insights_config[0].query_insights_enabled && !google_sql_database_instance.this.settings[0].insights_config[0].record_client_address
    error_message = "Query Insights on, without client addresses."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].backup_retention_settings[0].retained_backups == 14
    error_message = "14 backups retained by default."
  }
}

run "no_admin_user" {
  command = plan

  variables {
    admin_user = { create = false }
  }

  assert {
    condition     = length(google_sql_user.admin) == 0 && length(google_secret_manager_secret.admin) == 0
    error_message = "admin_user.create = false creates no user or secret."
  }
}

run "unencrypted_ssl_mode_refused" {
  command = plan

  variables {
    ssl_mode = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
  }

  expect_failures = [var.ssl_mode]
}

run "iam_authentication_off_wins_over_flags" {
  command = plan

  variables {
    iam_authentication = false
    database_flags     = { "cloudsql.iam_authentication" = "on" }
  }

  assert {
    condition     = one([for f in google_sql_database_instance.this.settings[0].database_flags : f.value if f.name == "cloudsql.iam_authentication"]) == "off"
    error_message = "iam_authentication = false yields cloudsql.iam_authentication off, whatever database_flags says."
  }
}

run "enterprise_refuses_perf_optimized_tier" {
  command = plan

  variables {
    tier = "db-perf-optimized-N-2"
  }

  expect_failures = [google_sql_database_instance.this]
}

run "enterprise_plus_refuses_custom_tier" {
  command = plan

  variables {
    edition = "ENTERPRISE_PLUS"
  }

  expect_failures = [google_sql_database_instance.this]
}

run "enterprise_pitr_window_capped" {
  command = plan

  variables {
    transaction_log_retention_days = 8
  }

  expect_failures = [google_sql_database_instance.this]
}
