output "function_name" {
  description = "Function (and Cloud Run service) name."
  value       = google_cloudfunctions2_function.this.name
}

output "function_uri" {
  description = "Internal-only HTTPS URI (push endpoint and scheduler target)."
  value       = local.function_uri
}

output "function_service_account_email" {
  description = "Runtime service account. Grant it Cloud SQL access (roles/cloudsql.client for the connector path) or search backend access as needed."
  value       = google_service_account.function.email
}

output "invoker_service_account_email" {
  description = "Identity Pub/Sub push and Cloud Scheduler use to invoke the function."
  value       = google_service_account.invoker.email
}

output "events_topic_id" {
  description = "session-events topic (SESSION_PIPELINE_TOPIC)."
  value       = google_pubsub_topic.events.id
}

output "dead_letter_topic_id" {
  description = "Dead-letter topic."
  value       = google_pubsub_topic.dlq.id
}

output "dead_letter_subscription_id" {
  description = "Pull subscription holding dead-lettered messages."
  value       = google_pubsub_subscription.dlq.id
}

output "secret_id" {
  description = "Pipeline secret (SESSION_PIPELINE_SECRET_ID). Add its JSON value out of band: the HoopDb URL (the chart's HOOPDB_URL value) and the search backend credentials."
  value       = local.secret_id
}
