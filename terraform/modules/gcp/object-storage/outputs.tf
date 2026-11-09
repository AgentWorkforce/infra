output "bucket_name" {
  description = "Bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider gcs, endpoint \"\"), or durable-actors storage.bucket."
  value       = google_storage_bucket.this.name
}

output "bucket_url" {
  description = "gs://<bucket>."
  value       = google_storage_bucket.this.url
}

output "location" {
  description = "Bucket location as given (a region, dual-region or multi-region)."
  value       = google_storage_bucket.this.location
}

output "region" {
  description = "The bucket's region when its location is a single region (null for dual- and multi-regions). Feeds worker.locker.region / alleyoop.locker.region."
  value       = can(regex("^[a-z]+-[a-z]+[0-9]+$", lower(var.location))) ? lower(var.location) : null
}

output "google_service_account_email" {
  description = "Workload Google service account (null unless workload_identity.google_service_account is set). Annotate the Kubernetes service accounts iam.gke.io/gcp-service-account=<email>; durable-actors takes it as serviceAccount.googleServiceAccount."
  value       = try(google_service_account.workload[0].email, null)
}
