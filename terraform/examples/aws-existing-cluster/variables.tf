# Required: your account and existing network.

variable "account_id" {
  description = "AWS account to install into. Terraform refuses to run against any other account."
  type        = string
}

variable "region" {
  description = "AWS region of your EKS cluster, e.g. us-east-1."
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of your existing EKS cluster."
  type        = string
}

variable "domain" {
  description = "Hostname for the app, e.g. ar.example.com. The certificate also covers api., cast. and history. under it."
  type        = string
}

variable "database_subnet_ids" {
  description = "Private subnets for the database, in at least two Availability Zones."
  type        = list(string)
}

variable "database_security_group_id" {
  description = "Security group for the database. Allow TCP 5432 from your EKS nodes or pods."
  type        = string
}

variable "sessions_bucket_name" {
  description = "Name for the new S3 bucket that holds session data. Must be globally unique."
  type        = string
}

# Search (Amazon OpenSearch). Turn off to use PostgreSQL search instead.

variable "enable_search" {
  description = "Create an Amazon OpenSearch domain for transcript search."
  type        = bool
  default     = true
}

variable "search_subnet_ids" {
  description = "Private subnets for OpenSearch, one per Availability Zone (three recommended)."
  type        = list(string)
  default     = []
}

variable "search_security_group_id" {
  description = "Security group for OpenSearch. Allow TCP 443 from your EKS nodes or pods."
  type        = string
  default     = null
}

variable "search_admin_role_arn" {
  description = "Existing IAM role that administers OpenSearch access. Not used by the app at runtime."
  type        = string
  default     = null
}

# Optional: sizes and settings. The defaults suit about 100 users.

variable "name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "agent-relay"
}

variable "namespace" {
  description = "Kubernetes namespace the Helm chart installs into."
  type        = string
  default     = "agent-relay"
}

variable "database_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.r7g.large"
}

variable "database_backup_retention_days" {
  description = "Days of automated database backups (point-in-time recovery)."
  type        = number
  default     = 35
}

variable "search_instance_type" {
  description = "OpenSearch data node type."
  type        = string
  default     = "r7g.large.search"
}

variable "kms_key_arn" {
  description = "Your KMS key for the database, bucket and search. null uses AWS-managed keys."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = { app = "agent-relay" }
}
