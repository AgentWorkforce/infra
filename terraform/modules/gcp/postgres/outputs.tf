output "instance_name" {
  description = "Instance name."
  value       = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "project:region:instance. Feeds the sessions-pipeline CLOUD_SQL_CONNECTION_NAME extraEnv in values-gcp.yaml (worker and alleyoop) and the Cloud SQL Auth Proxy, if used."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip_address" {
  description = "Private IP. The host part of every agent-relay database URL (relay-control database-url, relayhistory DATABASE_URL, sessions-pipeline HOOPDB_URL, durable-actors postgres-url)."
  value       = google_sql_database_instance.this.private_ip_address
}

output "dns_name" {
  description = "Cloud SQL server DNS name. With GOOGLE_MANAGED_CAS_CA, use this host with sslmode=verify-full and private DNS pointing it to private_ip_address."
  value       = try(trimsuffix(google_sql_database_instance.this.dns_name, "."), null)
}

output "port" {
  description = "Database port."
  value       = 5432
}

output "databases" {
  description = "Databases created by the module."
  value       = [for d in google_sql_database.this : d.name]
}

output "admin_username" {
  description = "Administrator (cloudsqlsuperuser) for the bootstrap SQL only (null when admin_user.create is false)."
  value       = local.create_admin ? google_sql_user.admin[0].name : null
}

output "admin_password_secret_id" {
  description = "Secret Manager secret holding the administrator password (projects/<p>/secrets/<id>). Read it from the bootstrap job; it is not in Terraform state."
  value       = local.create_admin ? google_secret_manager_secret.admin[0].id : null
}

output "server_ca_cert" {
  description = "Current server CA certificate (public PEM) for sslmode=verify-ca/verify-full."
  # The provider marks the whole block sensitive; a CA certificate is public.
  value = nonsensitive(google_sql_database_instance.this.server_ca_cert[0].cert)
}

output "database_url_template" {
  description = "Connection URL shape for chart Secrets. Shared-CA instances use their verified DNS identity; per-instance CA keeps the private-IP sslmode=require compatibility shape."
  value       = var.server_ca_mode == "GOOGLE_MANAGED_CAS_CA" ? "postgresql://<role>:<password>@${trimsuffix(google_sql_database_instance.this.dns_name, ".")}:5432/<database>?sslmode=verify-full" : "postgresql://<role>:<password>@${google_sql_database_instance.this.private_ip_address}:5432/<database>?sslmode=require"
}
