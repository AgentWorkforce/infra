# Optional: storage for relay-control's signed Desktop feed (relay-control
# 0.5.25+, SELFHOST_DESKTOP_FEED_STORAGE=gcs). A dedicated private bucket, a
# Google service account for relay-control reached through GKE Workload
# Identity, and signBlob on itself for V4 signed download URLs.
#
# Off by default, so existing installs plan no change. Set
# desktop_feed_bucket_name to turn it on. The project also needs
# iamcredentials.googleapis.com enabled (install guide step 2), and relay-control's
# Kubernetes service account needs both annotations in output.desktop_feed.
# The bucket holds only this feed, so bucket-wide object access is the
# <prefix>/profiles/* scope relay-control needs.

locals {
  desktop_feed_enabled = var.desktop_feed_bucket_name != ""
  relay_control_ksa    = "${var.release_name}-relay-control"
}

module "desktop_feed_bucket" {
  source = "../../modules/gcp/object-storage"
  count  = local.desktop_feed_enabled ? 1 : 0

  project_id   = var.project_id
  bucket_name  = var.desktop_feed_bucket_name
  location     = var.region
  kms_key_name = var.kms_key_name
  workload_identity = {
    google_service_account = {
      account_id   = var.desktop_feed_service_account_id
      display_name = "agent-relay relay-control (Desktop feed)"
      kubernetes_service_accounts = [
        { namespace = var.namespace, name = local.relay_control_ksa },
      ]
    }
  }
  labels = var.labels
}

# V4 signed download URLs: relay-control signs as its own service account
# through the IAM Credentials signBlob API.
resource "google_service_account_iam_member" "desktop_feed_sign_self" {
  count = local.desktop_feed_enabled ? 1 : 0

  service_account_id = "projects/${var.project_id}/serviceAccounts/${module.desktop_feed_bucket[0].google_service_account_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${module.desktop_feed_bucket[0].google_service_account_email}"
}
