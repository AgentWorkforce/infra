# Optional image mirror (install guide step 5): the Artifact Registry
# repository the release images are copied into, and read access on it for the
# GKE node service account, which pulls them. In a new project the default
# Compute Engine service account has no roles, so without this grant every
# pull fails with 403 and step 8's Job times out.
#
# Off by default, so applying this root to an install whose mirror was made by
# hand plans no change. A new install sets image_mirror_repository (the guide
# uses "agent-relay-mirror"); to adopt an existing repository instead, import it
# first: terraform import 'google_artifact_registry_repository.mirror[0]' \
#   projects/<project>/locations/<region>/repositories/<name>

locals {
  image_mirror_enabled = var.image_mirror_repository != ""
  gke_node_sa          = var.gke_node_service_account != "" ? var.gke_node_service_account : "${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_artifact_registry_repository" "mirror" {
  #checkov:skip=CKV_GCP_84:Holds copies of the public, digest-pinned release images; Google-managed encryption is the default.
  count = local.image_mirror_enabled ? 1 : 0

  project       = var.project_id
  location      = var.region
  repository_id = var.image_mirror_repository
  format        = "DOCKER"
  description   = "Agent Relay release images, copied by digest (install guide step 5)"
  labels        = var.labels
}

resource "google_artifact_registry_repository_iam_member" "mirror_node_reader" {
  count = local.image_mirror_enabled ? 1 : 0

  project    = var.project_id
  location   = google_artifact_registry_repository.mirror[0].location
  repository = google_artifact_registry_repository.mirror[0].name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.gke_node_sa}"
}
