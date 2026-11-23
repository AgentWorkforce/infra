# The broker role (in the layered-infra-ops host's account) and the scoped
# role it vends sandbox sessions on (805532413586). Applied by layered-infra-ops
# once this is merged to main (Khaliq, 2026-11-15): plan first, apply from main,
# never from a branch and never from CI. See ../../DESIGN.md.
#
# allowed_account_ids makes a run against the wrong account fail before it
# changes anything. infra-ops' default AWS profile is its admin role in its own
# account; to reach the sandbox it assumes sandbox_assume_role_arn (a role in
# 805532413586 that trusts that admin role) unless sandbox_profile is set.

provider "aws" {
  alias               = "broker"
  region              = var.region
  profile             = var.broker_profile
  allowed_account_ids = [var.broker_account_id]
}

provider "aws" {
  alias               = "sandbox"
  region              = var.region
  profile             = var.sandbox_profile
  allowed_account_ids = [var.sandbox_account_id]

  dynamic "assume_role" {
    for_each = var.sandbox_assume_role_arn == null ? [] : [var.sandbox_assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "layered-infra-ops-cred-broker-tf"
    }
  }
}

locals {
  # Approval-tier sessions in the broker's own account (the agent hosts'):
  # every one needs Khaliq's approval. The infra-ops host already has
  # administrator access here, so this adds no new reach (DESIGN.md).
  agent_hosts_elevated_role_arn = "arn:aws:iam::${var.broker_account_id}:role/agent-broker-elevated"
  scoped_role_name              = "agent-broker-sandbox-scoped"
  scoped_role_arn               = "arn:aws:iam::${var.sandbox_account_id}:role/${local.scoped_role_name}"
  # The read-only prod-cluster role (created by ../prod). Read from the
  # allowlist by label, so the broker's target and the allowlist cannot differ.
  prod_read_role_arn = one([for a in values(jsondecode(file("${path.module}/../../allowlist.json")).accounts) : a.roles.elevated if a.label == "agentrelay-prod"])
  # The read-only session-pipeline role in the sessions account (created by
  # ../sessions, which the owner applies himself). Same rule: by label.
  sessions_read_role_arn = one([for a in values(jsondecode(file("${path.module}/../../allowlist.json")).accounts) : a.roles.elevated if a.label == "sessions-prod"])
}

# The dev account's read-only role is created by that account's owner, by hand
# (../dev), not here: this root only lets the broker assume it.

module "broker_role" {
  source    = "../modules/broker-role"
  providers = { aws = aws.broker }

  account_id             = var.broker_account_id
  trusted_principal_arns = [var.broker_host_role_arn]
  target_role_arns       = [local.scoped_role_arn, local.agent_hosts_elevated_role_arn, var.dev_read_role_arn, local.prod_read_role_arn, local.sessions_read_role_arn]
  audit_log_group_arn    = module.audit_log.arn
}

# The audit log's copy in CloudWatch, in the broker's account and region (the
# host ships to it every minute: broker/src/ship.ts, setup-lane.sh).
module "audit_log" {
  source    = "../modules/audit-log"
  providers = { aws = aws.broker }
}

module "sandbox_scoped_role" {
  source    = "../modules/scoped-role"
  providers = { aws = aws.sandbox }

  name            = local.scoped_role_name
  broker_role_arn = module.broker_role.role_arn
  allowed_regions = var.allowed_regions
}

module "agent_hosts_elevated_role" {
  source    = "../modules/elevated-role"
  providers = { aws = aws.broker }

  broker_role_arn = module.broker_role.role_arn
  allowed_regions = var.allowed_regions
}
