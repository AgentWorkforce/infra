output "database_host" {
  description = "RDS endpoint."
  value       = module.database.host
}

output "database_admin_secret_arn" {
  description = "Secrets Manager secret holding the RDS admin password. Used once, for database setup."
  value       = module.database.master_user_secret_arn
}

output "sessions_bucket" {
  description = "S3 bucket for session data."
  value       = module.sessions_bucket.bucket_name
}

output "sessions_role_arn" {
  description = "IAM role the app uses for the bucket, bound through EKS Pod Identity."
  value       = module.sessions_bucket.access_role_arn
}

output "search_url" {
  description = "OpenSearch endpoint (null when search is off)."
  value       = var.enable_search ? module.search[0].url : null
}

output "search_roles" {
  description = "OpenSearch indexer (write) and reader (read-only) roles (null when search is off)."
  value = var.enable_search ? {
    indexer = module.search[0].indexer_role_arn
    reader  = module.search[0].reader_role_arn
  } : null
}

output "certificate_arn" {
  description = "ACM certificate for the app's hostnames. Pass it to the Helm install."
  value       = aws_acm_certificate.app.arn
}

output "certificate_dns_records" {
  description = "Create these CNAME records in your DNS to validate the certificate."
  value = [
    for o in aws_acm_certificate.app.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}
