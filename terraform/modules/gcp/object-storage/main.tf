locals {
  # Workloads get object access only; other roles go through iam_members.
  wi_role       = "roles/storage.objectUser"
  wi            = var.workload_identity
  wi_pool       = local.wi == null ? null : coalesce(local.wi.workload_pool, "${var.project_id}.svc.id.goog")
  create_gsa    = local.wi != null && try(local.wi.google_service_account, null) != null
  direct_ksas   = local.wi == null ? [] : local.wi.direct_kubernetes_service_accounts
  needs_project = length(local.direct_ksas) > 0
  # The principal names the project that owns the workload pool
  # (<pool project>.svc.id.goog), which may differ from the bucket's.
  wi_pool_project = local.wi_pool == null ? null : trimsuffix(local.wi_pool, ".svc.id.goog")

  # Static keys only: members such as the new GSA email are unknown at plan time.
  iam_members_flat = merge(
    merge([for role, members in var.iam_members : { for m in members : "extra/${role}/${m}" => { role = role, member = m } }]...),
    local.create_gsa ? { "wi/gsa" = { role = local.wi_role, member = "serviceAccount:${google_service_account.workload[0].email}" } } : {},
    { for k in local.direct_ksas : "wi/direct/${k.namespace}/${k.name}" => {
      role   = local.wi_role
      member = "principal://iam.googleapis.com/projects/${data.google_project.this[0].number}/locations/global/workloadIdentityPools/${local.wi_pool}/subject/ns/${k.namespace}/sa/${k.name}"
    } },
  )
}

data "google_project" "this" {
  count      = local.needs_project ? 1 : 0
  project_id = local.wi_pool_project
}

resource "google_storage_bucket" "this" {
  project                     = var.project_id
  name                        = var.bucket_name
  location                    = var.location
  storage_class               = var.storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy
  labels                      = var.labels

  versioning {
    enabled = var.versioning_enabled
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_seconds
  }

  dynamic "encryption" {
    for_each = var.kms_key_name == null ? [] : [1]
    content {
      default_kms_key_name = var.kms_key_name
    }
  }

  dynamic "logging" {
    for_each = var.access_log_bucket == null ? [] : [1]
    content {
      log_bucket        = var.access_log_bucket
      log_object_prefix = var.bucket_name
    }
  }

  lifecycle_rule {
    action {
      type = "AbortIncompleteMultipartUpload"
    }
    condition {
      age = var.abort_incomplete_multipart_upload_days
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.versioning_enabled && var.noncurrent_version_retention_days > 0 ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        days_since_noncurrent_time = var.noncurrent_version_retention_days
        with_state                 = "ARCHIVED"
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.lifecycle_rules
    content {
      action {
        type          = lifecycle_rule.value.action_type
        storage_class = lifecycle_rule.value.storage_class
      }
      condition {
        age                = lifecycle_rule.value.age_days
        matches_prefix     = lifecycle_rule.value.matches_prefix
        with_state         = lifecycle_rule.value.with_state
        num_newer_versions = lifecycle_rule.value.num_newer_versions
      }
    }
  }
}

resource "google_service_account" "workload" {
  count = local.create_gsa ? 1 : 0

  project      = var.project_id
  account_id   = local.wi.google_service_account.account_id
  display_name = coalesce(local.wi.google_service_account.display_name, "agent-relay ${var.bucket_name}")
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = local.create_gsa ? { for k in local.wi.google_service_account.kubernetes_service_accounts : "${k.namespace}/${k.name}" => k } : {}

  service_account_id = google_service_account.workload[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.wi_pool}[${each.value.namespace}/${each.value.name}]"
}

resource "google_storage_bucket_iam_member" "this" {
  for_each = local.iam_members_flat

  bucket = google_storage_bucket.this.name
  role   = each.value.role
  member = each.value.member
}
