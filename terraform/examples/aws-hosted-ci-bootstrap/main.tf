terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.72, < 7.0" }
  }
  backend "s3" {}
}
provider "aws" {
  region              = var.settings.region
  allowed_account_ids = [var.settings.account_id]
}
variable "settings" {
  description = "Private bootstrap coordinates supplied by protected CI."
  type = object({
    region         = string
    account_id     = string
    bucket         = string
    state_key      = string
    plan_prefix    = string
    parameter      = string
    name           = string
    repository_id  = string
    subject_prefix = string
    workflow       = string
    environment    = string
    mapping_id     = string
    create_oidc    = optional(bool, false)
  })
}
variable "private_tfvars" {
  type      = string
  ephemeral = true
  sensitive = true
  validation {
    condition     = can(keys(jsondecode(var.private_tfvars)))
    error_message = "A private JSON object is required."
  }
}
variable "tfvars_version" {
  type = number
  validation {
    condition     = var.tfvars_version >= 1 && floor(var.tfvars_version) == var.tfvars_version
    error_message = "Supply a positive integer revision."
  }
}
locals {
  issuer = "https://token.actions.githubusercontent.com"
}
data "aws_iam_openid_connect_provider" "existing" {
  count = var.settings.create_oidc ? 0 : 1
  url   = local.issuer
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.settings.create_oidc ? 1 : 0
  url            = local.issuer
  client_id_list = ["sts.amazonaws.com"]
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_key" "state" {
  enable_key_rotation = true
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket" "state" {
  bucket = var.settings.bucket
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}
resource "aws_s3_bucket_policy" "transport" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny", Principal = "*", Action = "s3:*",
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"],
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
resource "aws_ssm_parameter" "tfvars" {
  name             = var.settings.parameter
  type             = "SecureString"
  tier             = "Intelligent-Tiering"
  key_id           = aws_kms_key.state.arn
  value_wo         = var.private_tfvars
  value_wo_version = var.tfvars_version
  lifecycle { prevent_destroy = true }
}
module "ci" {
  source                   = "../../modules/aws/ci-terraform"
  name                     = var.settings.name
  github_oidc_provider_arn = var.settings.create_oidc ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
  repository_id            = var.settings.repository_id
  oidc_subject_prefix      = var.settings.subject_prefix
  workflow                 = var.settings.workflow
  apply_environment        = var.settings.environment
  state                    = { bucket = aws_s3_bucket.state.id, key = var.settings.state_key, kms_key_arn = aws_kms_key.state.arn }
  plan_store_prefix        = var.settings.plan_prefix
  tfvars_parameter_name    = aws_ssm_parameter.tfvars.name
  adoption_mapping_id      = var.settings.mapping_id
  stack                    = { name = var.settings.name, environment = var.settings.environment, kms_key_arn = aws_kms_key.state.arn, eks_cluster_name = var.settings.name }
}

output "workflow_settings" {
  value     = module.ci.ci
  sensitive = true
}
