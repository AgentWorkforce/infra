mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "relay-sessions@proj.iam.gserviceaccount.com"
      name  = "projects/proj/serviceAccounts/relay-sessions@proj.iam.gserviceaccount.com"
    }
  }
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
}

variables {
  project_id  = "proj"
  bucket_name = "relay-sessions"
  location    = "us-central1"
}

run "defaults_are_private" {
  command = apply

  assert {
    condition     = google_storage_bucket.this.public_access_prevention == "enforced"
    error_message = "Public access prevention must be enforced."
  }
  assert {
    condition     = google_storage_bucket.this.uniform_bucket_level_access
    error_message = "Uniform bucket-level access (no ACLs)."
  }
  assert {
    condition     = google_storage_bucket.this.versioning[0].enabled && google_storage_bucket.this.force_destroy == false
    error_message = "Versioning on, force_destroy off."
  }
  assert {
    condition     = length(google_storage_bucket_iam_member.this) == 0
    error_message = "No IAM bindings by default."
  }
  assert {
    condition     = one(google_storage_bucket.this.soft_delete_policy).retention_duration_seconds == 604800
    error_message = "7-day soft delete by default."
  }
  assert {
    condition     = contains([for r in google_storage_bucket.this.lifecycle_rule : one(r.condition).age if one(r.action).type == "AbortIncompleteMultipartUpload"], 7)
    error_message = "Incomplete multipart uploads are aborted after 7 days."
  }
  assert {
    condition     = contains([for r in google_storage_bucket.this.lifecycle_rule : one(r.condition).days_since_noncurrent_time if one(r.action).type == "Delete"], 30)
    error_message = "Noncurrent versions are deleted after 30 days."
  }
}

run "workload_identity" {
  command = apply

  variables {
    workload_identity = {
      google_service_account = {
        account_id                  = "relay-sessions"
        kubernetes_service_accounts = [{ namespace = "agent-relay", name = "agent-relay-worker" }]
      }
      direct_kubernetes_service_accounts = [{ namespace = "agent-relay", name = "agent-relay-alleyoop" }]
    }
  }

  assert {
    condition     = google_service_account_iam_member.workload_identity["agent-relay/agent-relay-worker"].member == "serviceAccount:proj.svc.id.goog[agent-relay/agent-relay-worker]"
    error_message = "The KSA may impersonate the GSA."
  }
  assert {
    condition     = contains([for m in google_storage_bucket_iam_member.this : m.member], "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/proj.svc.id.goog/subject/ns/agent-relay/sa/agent-relay-alleyoop")
    error_message = "Direct WI principal is bound on the bucket."
  }
  assert {
    condition     = alltrue([for m in google_storage_bucket_iam_member.this : m.role == "roles/storage.objectUser"])
    error_message = "Workloads get objectUser only, never admin."
  }
  assert {
    condition     = alltrue([for m in google_storage_bucket_iam_member.this : !contains(["allUsers", "allAuthenticatedUsers"], m.member)])
    error_message = "No public members."
  }
}

run "cross_project_pool_uses_pool_project" {
  command = plan

  # The pool's project gets a distinct number from the mock default.
  override_data {
    target = data.google_project.this
    values = { number = "999999999999" }
  }

  variables {
    workload_identity = {
      workload_pool                      = "cluster-proj.svc.id.goog"
      direct_kubernetes_service_accounts = [{ namespace = "agent-relay", name = "agent-relay-worker" }]
    }
  }

  assert {
    condition     = data.google_project.this[0].project_id == "cluster-proj" && google_storage_bucket_iam_member.this["wi/direct/agent-relay/agent-relay-worker"].member == "principal://iam.googleapis.com/projects/999999999999/locations/global/workloadIdentityPools/cluster-proj.svc.id.goog/subject/ns/agent-relay/sa/agent-relay-worker"
    error_message = "The principal names the pool project's number."
  }
}
