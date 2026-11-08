terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.72, < 7.0" }
  }
  backend "s3" {}
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
module "foundation" {
  source                      = "../../modules/aws/foundation"
  deletion_protection         = var.deletion_protection
  account_id                  = var.account_id
  region                      = var.region
  environment                 = var.environment
  name_prefix                 = var.name_prefix
  kubernetes_version          = var.kubernetes_version
  addon_versions              = var.addon_versions
  vpc_cidr                    = var.vpc_cidr
  subnets                     = var.subnets
  search_az_count             = var.search_az_count
  actor_availability_zone     = var.actor_availability_zone
  public_api_enabled          = var.public_api_enabled
  operator_cidrs              = var.operator_cidrs
  operator_security_group_ids = var.operator_security_group_ids
  operator_role_arns          = var.operator_role_arns
  kms_key_arn                 = var.kms_key_arn
  instance_type               = var.instance_type
  actor_instance_type         = var.actor_instance_type
  node_ami_release_version    = var.node_ami_release_version
  capacity                    = var.capacity
  actor_capacity              = var.actor_capacity
  namespace                   = var.namespace
  release_name                = var.release_name
  pippen                      = var.pippen
  tags                        = var.tags

  enable_load_balancer_controller = var.enable_load_balancer_controller
}
