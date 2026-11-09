data "aws_caller_identity" "plan" {}
data "aws_region" "current" {}
data "aws_subnet" "first" { id = var.subnet_ids[0] }
data "aws_subnet" "second" {
  count = length(var.subnet_ids) == 2 ? 1 : 0
  id    = var.subnet_ids[1]
}
data "aws_security_group" "domain" { id = var.domain_security_group_id }
data "aws_security_group" "clients" {
  for_each = var.client_security_group_ids
  id       = each.value
}
locals {
  domain_name    = "pippen-sbx-${substr(sha256(var.pippen.session_id), 0, 10)}-search"
  common_caller  = "arn:aws:sts::${var.account_id}:assumed-role/agent-session/agent-${var.pippen.session_id}"
  control_role   = "arn:aws:iam::${var.account_id}:role/pippen/provisioning/search-control-v1-${var.pippen.session_id}"
  control_caller = "arn:aws:sts::${var.account_id}:assumed-role/search-control-v1-${var.pippen.session_id}/search-${var.pippen.session_id}"
  subnets        = concat([data.aws_subnet.first], data.aws_subnet.second)
  tags = {
    "pippen:sandbox" = "true"
    "pippen:agent"   = var.pippen.agent
    "pippen:session" = var.pippen.session_id
    "proof:source"   = var.source_sha
    Environment      = "disposable-search"
    EnvironmentClass = "development"
    ManagedBy        = "terraform"
  }
}
resource "terraform_data" "guard" {
  input = { source_sha = var.source_sha, account_id = var.account_id, lease = var.pippen, domain = local.domain_name, disposable = true, tags = local.tags, roles = var.roles }
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.plan.account_id == var.account_id && data.aws_region.current.region == var.region && contains([local.common_caller, local.control_caller], data.aws_caller_identity.plan.arn)
      error_message = "Refuse a foreign account/region/lease planner. This data source records plan identity; it never authorizes saved-plan apply."
    }
    precondition {
      condition     = alltrue([for key in keys(local.tags) : contains(var.approved_tag_keys, key)]) && length(var.approved_tag_keys) <= 8
      error_message = "Every immutable tag key must be approved by the closed search profile."
    }
    precondition {
      condition     = alltrue([for subnet in local.subnets : subnet.owner_id == var.account_id && subnet.vpc_id == var.vpc_id && !subnet.map_public_ip_on_launch && subnet.available_ip_address_count >= 8]) && length(distinct([for subnet in local.subnets : subnet.availability_zone])) == length(var.subnet_ids)
      error_message = "Require same-account/VPC private distinct AZ subnets with spare addresses; native DNS/routes/NACL/capacity checks remain mandatory external prerequisites."
    }
    precondition {
      condition     = length(distinct(values(var.roles))) == 3 && alltrue([for arn in values(var.roles) : can(regex("^arn:aws:iam::${var.account_id}:role/[A-Za-z0-9+=,.@_/-]+$", arn)) && !startswith(arn, "arn:aws:iam::${var.account_id}:role/pippen/provisioning/") && !contains(["arn:aws:iam::${var.account_id}:role/agent-session", "arn:aws:iam::${var.account_id}:role/pippen/agent-session"], arn)])
      error_message = "Require three distinct same-account external role ARNs, separate from control/common callers."
    }
    precondition {
      condition     = data.aws_security_group.domain.arn == "arn:aws:ec2:${var.region}:${var.account_id}:security-group/${var.domain_security_group_id}"
      error_message = "Require a same-account existing domain SG; native peer-only ingress and exclusive ENI baseline checks are mandatory before apply."
    }
    precondition {
      condition     = data.aws_security_group.domain.vpc_id == var.vpc_id && !contains(var.client_security_group_ids, var.domain_security_group_id) && alltrue([for id, group in data.aws_security_group.clients : group.vpc_id == var.vpc_id && group.arn == "arn:aws:ec2:${var.region}:${var.account_id}:security-group/${id}"])
      error_message = "Domain and distinct client SGs must be in the exact existing account/region/VPC; rule inspection remains native common-role preflight."
    }
  }
}
module "search" {
  #checkov:skip=CKV_AWS_318:Bounded disposable proof has no dedicated masters; it makes no HA claim.
  #checkov:skip=CKV2_AWS_59:New disposable single/two-node proof disables dedicated masters; no production or HA claim. The protected branch has count zero in this root.
  #checkov:skip=CKV_AWS_317:No content-bearing audit/application logs or account-level log policy are created by this narrow control proof.
  source                        = "../../modules/aws/search"
  disposable                    = true
  domain_name                   = local.domain_name
  engine_version                = var.engine_version
  subnet_ids                    = var.subnet_ids
  security_group_ids            = [var.domain_security_group_id]
  master_user_arn               = var.roles.admin
  additional_principal_arns     = [var.roles.indexer, var.roles.reader]
  workload_roles                = { create = false }
  instance_type                 = "t3.small.search"
  instance_count                = length(var.subnet_ids)
  dedicated_master_enabled      = false
  multi_az_with_standby_enabled = false
  ebs_volume_size               = 20
  ebs_volume_type               = "gp3"
  log_publishing                = []
  create_log_resource_policy    = false
  tags                          = local.tags
  # Guard inputs are independent existing-resource data/required variables and
  # therefore checked during planning. A module-wide dependency would defer its
  # caller/region/partition reads and hide the permission-bearing policy JSON.
  # Fresh apply authority is checked by the external source runner, not this
  # plan-time resource or a cached Terraform identity data source.
}
