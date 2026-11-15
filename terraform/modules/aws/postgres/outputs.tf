locals {
  writer_endpoint = !var.enabled ? null : local.aurora ? aws_rds_cluster.this[0].endpoint : aws_db_instance.this[0].address
  reader_endpoint = var.enabled && local.aurora ? aws_rds_cluster.this[0].reader_endpoint : null
  master_secret   = !var.enabled ? null : local.aurora ? aws_rds_cluster.this[0].master_user_secret : aws_db_instance.this[0].master_user_secret
}

output "enabled" {
  description = "Whether the database exists. false (enabled = false) creates no AWS resource and every connection output is null."
  value       = var.enabled
}

output "engine_mode" {
  description = "\"rds\" or \"aurora\"."
  value       = var.engine_mode
}

output "host" {
  description = "Writer endpoint host name. The host part of every agent-relay database URL (relay-control database-url, relayhistory DATABASE_URL, sessions-pipeline HOOPDB_URL, durable-actors postgres-url)."
  value       = local.writer_endpoint
}

output "reader_host" {
  description = "Aurora reader endpoint (null for RDS). No agent-relay component reads from replicas."
  value       = local.reader_endpoint
}

output "port" {
  description = "Database port."
  value       = var.port
}

output "initial_database" {
  description = "The database created with the instance."
  value       = var.database_name
}

output "master_username" {
  description = "Master (rds_superuser) user. Use it only for the bootstrap SQL in the README, never as an application role."
  value       = var.master_username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret (JSON keys username, password) that RDS manages and rotates for the master user. Read it from the bootstrap job or an External Secrets Operator ExternalSecret; the password never enters Terraform state."
  value       = var.enabled ? local.master_secret[0].secret_arn : null
}

output "database_url_template" {
  description = "Connection URL shape for the chart Secrets, with placeholders for role, password and database. sslmode=verify-full needs the RDS CA bundle in the trust store; sslmode=require is the minimum with force_ssl."
  value       = var.enabled ? "postgresql://<role>:<password>@${local.writer_endpoint}:${var.port}/<database>?sslmode=verify-full" : null
}

output "instance_identifier" {
  description = "RDS instance identifier (null for Aurora)."
  value       = var.enabled && !local.aurora ? aws_db_instance.this[0].identifier : null
}

output "cluster_identifier" {
  description = "Aurora cluster identifier (null for RDS)."
  value       = var.enabled && local.aurora ? aws_rds_cluster.this[0].cluster_identifier : null
}

output "resource_arn" {
  description = "ARN of the RDS instance or Aurora cluster."
  value       = !var.enabled ? null : local.aurora ? aws_rds_cluster.this[0].arn : aws_db_instance.this[0].arn
}

output "db_subnet_group_name" {
  description = "DB subnet group in use."
  value       = var.enabled ? local.subnet_group_name : null
}
