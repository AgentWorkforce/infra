data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name      = "${var.name_prefix}-${var.environment}"
  azs       = sort(keys(var.subnets))
  namespace = coalesce(var.namespace, "agent-relay-${var.environment}")
  role_path = var.pippen == null ? "/" : "/pippen/workload/"
  boundary  = var.pippen == null ? null : "arn:aws:iam::${var.account_id}:policy/pippen-agent-session-boundary"
  tags = merge(var.tags, { Environment = var.environment, ManagedBy = "terraform" }, var.pippen == null ? {} : {
    "pippen:sandbox" = "true"
    "pippen:agent"   = var.pippen.agent
    "pippen:session" = var.pippen.session_id
  })
}

locals {
  network_cidrs = concat([var.vpc_cidr], flatten([for s in values(var.subnets) : [s.public_cidr, s.private_cidr]]))
  # IPv4 intervals make containment and overlap checks independent of live AWS.
  network_ranges = [for c in local.network_cidrs : {
    first = try(sum([for i, octet in split(".", cidrhost(c, 0)) : tonumber(octet) * pow(256, 3 - i)]), -1)
    last  = try(sum([for i, octet in split(".", cidrhost(c, -1)) : tonumber(octet) * pow(256, 3 - i)]), -1)
  }]
  subnet_ranges = slice(local.network_ranges, 1, length(local.network_ranges))
}
resource "terraform_data" "guard" {
  input = { account_id = var.account_id, environment = var.environment }
  lifecycle {
    precondition {
      condition     = alltrue([for r in local.subnet_ranges : r.first >= local.network_ranges[0].first && r.last <= local.network_ranges[0].last]) && alltrue(flatten([for i, a in local.subnet_ranges : [for j, b in local.subnet_ranges : i == j || a.last < b.first || b.last < a.first]]))
      error_message = "All public/private subnet CIDRs must be inside the VPC and mutually disjoint."
    }
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id && data.aws_region.current.region == var.region
      error_message = "Caller account/provider region must exactly match the foundation target."
    }
    precondition {
      condition     = length(local.name) <= 21
      error_message = "name_prefix-environment must fit in 21 characters for downstream OpenSearch names."
    }
    precondition {
      condition     = !var.public_api_enabled || length(var.operator_cidrs) > 0
      error_message = "Public API access requires explicit bounded operator CIDRs; no implicit 0.0.0.0/0."
    }
    precondition {
      condition     = length(var.operator_cidrs) + length(var.operator_security_group_ids) > 0
      error_message = "Supply an explicit private operator network/SG access path."
    }
    precondition {
      condition     = alltrue([for a in var.operator_role_arns : startswith(a, "arn:aws:iam::${var.account_id}:role/")]) && startswith(var.kms_key_arn, "arn:aws:kms:${var.region}:${var.account_id}:key/")
      error_message = "Operator roles and durable encryption key must belong to the target account/region."
    }
    precondition {
      condition     = contains(local.azs, var.actor_availability_zone) && var.search_az_count <= length(local.azs) && alltrue([for az in local.azs : can(regex("^${var.region}[a-z]$", az))])
      error_message = "Actor AZ and search AZ count must fit the explicit region subnet map."
    }
    precondition {
      condition     = var.pippen == null ? true : (startswith(var.name_prefix, "pippen-sbx-") && data.aws_caller_identity.current.arn == "arn:aws:sts::${var.account_id}:assumed-role/agent-session/agent-${var.pippen.session_id}")
      error_message = "Pippen requires pippen-sbx naming and the exact expected allocated lease caller."
    }
  }
}
