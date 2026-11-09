locals {
  # The module-controlled flag comes last, so iam_authentication always wins.
  database_flags = merge(
    var.database_flags,
    { "cloudsql.iam_authentication" = var.iam_authentication ? "on" : "off" },
  )

  create_admin    = var.admin_user.create
  admin_secret_id = coalesce(var.admin_user.secret_id, "${var.name}-admin-password")

  # One generation number drives both write-only destinations, so the user
  # and the secret are always rewritten together with the same ephemeral
  # value: it changes with password_version and with anything that replaces
  # either destination (secret id, user name, instance name).
  admin_password_generation = var.admin_user.password_version * 16777216 + parseint(substr(sha1(join("/", [var.project_id, var.name, var.admin_user.name, local.admin_secret_id])), 0, 6), 16)
}

resource "google_sql_database_instance" "this" {
  #checkov:skip=CKV2_GCP_13:log_duration logs every statement's duration; opt in with database_flags.
  #checkov:skip=CKV_GCP_51:On by default through var.database_flags (checkov cannot resolve the dynamic block).
  #checkov:skip=CKV_GCP_52:On by default through var.database_flags (checkov cannot resolve the dynamic block).
  #checkov:skip=CKV_GCP_53:On by default through var.database_flags (checkov cannot resolve the dynamic block).
  #checkov:skip=CKV_GCP_54:On by default through var.database_flags (checkov cannot resolve the dynamic block).
  #checkov:skip=CKV_GCP_6:ssl_mode ENCRYPTED_ONLY (default) or TRUSTED_CLIENT_CERTIFICATE_REQUIRED; unencrypted modes are refused by validation.
  #checkov:skip=CKV_GCP_79:PostgreSQL 17 is the version the agent-relay services are tested on (database_version).
  #checkov:skip=CKV_GCP_108:Hostname logging adds a reverse DNS lookup per connection; set log_hostname in database_flags if wanted.
  #checkov:skip=CKV_GCP_109:log_min_messages keeps the Cloud SQL default (warning); set it in database_flags.
  #checkov:skip=CKV_GCP_110:pgAudit is opt-in (cloudsql.enable_pgaudit in database_flags).
  #checkov:skip=CKV_GCP_111:Statement logging would log transcript-bearing SQL; opt in with log_statement in database_flags.
  project             = var.project_id
  region              = var.region
  name                = var.name
  database_version    = var.database_version
  encryption_key_name = var.kms_key_name
  deletion_protection = var.deletion_protection

  lifecycle {
    precondition {
      condition     = var.edition == "ENTERPRISE_PLUS" ? startswith(var.tier, "db-perf-optimized-") : !startswith(var.tier, "db-perf-optimized-")
      error_message = "ENTERPRISE_PLUS needs a db-perf-optimized-N-<vCPU> tier; ENTERPRISE needs a shared-core or db-custom tier."
    }
    precondition {
      condition     = var.transaction_log_retention_days >= 1 && var.transaction_log_retention_days <= (var.edition == "ENTERPRISE_PLUS" ? 35 : 7)
      error_message = "transaction_log_retention_days must be 1-7 for ENTERPRISE or 1-35 for ENTERPRISE_PLUS."
    }
  }

  settings {
    edition                     = var.edition
    tier                        = var.tier
    availability_type           = var.availability_type
    disk_type                   = var.disk_type
    disk_size                   = var.disk_size_gb
    disk_autoresize             = true
    disk_autoresize_limit       = var.disk_autoresize_limit_gb
    deletion_protection_enabled = var.deletion_protection
    user_labels                 = var.labels

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.network_self_link
      allocated_ip_range                            = var.allocated_ip_range
      ssl_mode                                      = var.ssl_mode
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = var.backup_start_time
      location                       = var.backup_location
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.transaction_log_retention_days
      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = var.maintenance_window.day
      hour         = var.maintenance_window.hour
      update_track = var.maintenance_window.update_track
    }

    insights_config {
      query_insights_enabled  = var.query_insights_enabled
      record_application_tags = false
      record_client_address   = false
    }

    dynamic "database_flags" {
      for_each = local.database_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
  }
}

resource "google_sql_database" "this" {
  for_each = toset(var.databases)

  project  = var.project_id
  instance = google_sql_database_instance.this.name
  name     = each.value
}

# ---------------------------------------------------------------------------
# Administrator (bootstrap only): password never in state or plan
# ---------------------------------------------------------------------------

ephemeral "random_password" "admin" {
  count = local.create_admin ? 1 : 0

  length           = 32
  special          = true
  override_special = "-_.~"
}

resource "google_secret_manager_secret" "admin" {
  count = local.create_admin ? 1 : 0

  project   = var.project_id
  secret_id = local.admin_secret_id
  labels    = var.labels

  replication {
    dynamic "auto" {
      for_each = length(var.admin_user.secret_locations) == 0 ? [1] : []
      content {
        dynamic "customer_managed_encryption" {
          for_each = var.admin_user.secret_kms_key == null ? [] : [1]
          content {
            kms_key_name = var.admin_user.secret_kms_key
          }
        }
      }
    }
    dynamic "user_managed" {
      for_each = length(var.admin_user.secret_locations) == 0 ? [] : [1]
      content {
        dynamic "replicas" {
          for_each = var.admin_user.secret_locations
          content {
            location = replicas.value
            dynamic "customer_managed_encryption" {
              for_each = var.admin_user.secret_kms_key == null ? [] : [1]
              content {
                kms_key_name = var.admin_user.secret_kms_key
              }
            }
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "admin" {
  count = local.create_admin ? 1 : 0

  secret                 = google_secret_manager_secret.admin[0].id
  secret_data_wo         = ephemeral.random_password.admin[0].result
  secret_data_wo_version = local.admin_password_generation

  # A replaced user (for example a recreated instance) gets a fresh password:
  # write the same value to a new version.
  lifecycle {
    replace_triggered_by = [google_sql_user.admin]
  }
}

resource "google_sql_user" "admin" {
  count = local.create_admin ? 1 : 0

  project             = var.project_id
  instance            = google_sql_database_instance.this.name
  name                = var.admin_user.name
  type                = "BUILT_IN"
  password_wo         = ephemeral.random_password.admin[0].result
  password_wo_version = local.admin_password_generation
}
