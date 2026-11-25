# Plan-only, mocked providers: no AWS credentials, no state, no apply.
mock_provider "aws" {
  alias = "broker"
  override_resource {
    target          = module.broker_role.aws_iam_role.broker
    override_during = plan
    values          = { arn = "arn:aws:iam::500268966557:role/agent-cred-broker" }
  }
  override_resource {
    target          = module.agent_hosts_elevated_role.aws_iam_role.elevated
    override_during = plan
    values          = { arn = "arn:aws:iam::500268966557:role/agent-broker-elevated" }
  }
  override_resource {
    target          = module.audit_log.aws_cloudwatch_log_group.audit
    override_during = plan
    values          = { arn = "arn:aws:logs:us-east-1:500268966557:log-group:/aws-cred-broker/audit" }
  }
}

mock_provider "aws" {
  alias = "sandbox"
  override_resource {
    target          = module.sandbox_scoped_role.aws_iam_role.scoped
    override_during = plan
    values          = { arn = "arn:aws:iam::805532413586:role/agent-broker-sandbox-scoped" }
  }
}

variables {
  broker_account_id    = "500268966557"
  broker_host_role_arn = "arn:aws:iam::500268966557:role/layered-agent-infra-ops-dev"
}

run "wires_broker_to_its_roles_and_matches_the_allowlist" {
  command = plan
  assert {
    condition     = output.sandbox_scoped_role_arn == jsondecode(file("${path.module}/../../allowlist.json")).accounts["805532413586"].roles.scoped
    error_message = "the allowlist's scoped role is the one this creates"
  }
  assert {
    condition     = output.agent_hosts_elevated_role_arn == jsondecode(file("${path.module}/../../allowlist.json")).accounts["500268966557"].roles.elevated
    error_message = "the allowlist's elevated role for the broker account is the one this creates"
  }
  assert {
    condition     = jsondecode(file("${path.module}/../../allowlist.json")).accounts["500268966557"].tier == "prod"
    error_message = "the broker account is approval-tier only: no automatic issue"
  }
  # Not just the mocked ARN: the role actually planned, and the broker's real vend targets, match the allowlist.
  assert {
    condition     = module.agent_hosts_elevated_role.role_name == split("/", jsondecode(file("${path.module}/../../allowlist.json")).accounts["500268966557"].roles.elevated)[1]
    error_message = "the planned role's name is the allowlist's"
  }
  assert {
    condition = toset(module.broker_role.permissions_policy.Statement[0].Resource) == toset([
      jsondecode(file("${path.module}/../../allowlist.json")).accounts["805532413586"].roles.scoped,
      jsondecode(file("${path.module}/../../allowlist.json")).accounts["500268966557"].roles.elevated,
      jsondecode(file("${path.module}/../../allowlist.json")).accounts["154551280135"].roles.elevated,
      one([for a in values(jsondecode(file("${path.module}/../../allowlist.json")).accounts) : a.roles.elevated if a.label == "agentrelay-prod"]),
      one([for a in values(jsondecode(file("${path.module}/../../allowlist.json")).accounts) : a.roles.elevated if a.label == "sessions-prod"]),
    ]) && length(module.broker_role.permissions_policy.Statement[0].Resource) == 5 && length(jsondecode(file("${path.module}/../../allowlist.json")).accounts) == 5
    error_message = "the broker may vend into exactly the allowlist's roles"
  }
  assert {
    condition     = module.broker_role.permissions_policy.Statement[1].Sid == "ShipAuditLog" && module.broker_role.permissions_policy.Statement[1].Resource[0] == "arn:aws:logs:us-east-1:500268966557:log-group:/aws-cred-broker/audit"
    error_message = "the broker role may append to the audit group this creates, in its own account"
  }
  assert {
    condition     = output.audit_log_group_name == "/aws-cred-broker/audit"
    error_message = "the group the host ships to"
  }
  assert {
    condition     = strcontains(file("${path.module}/../../../setup-lane.sh"), "BROKER_AUDIT_LOG_REGION=${var.region}\n")
    error_message = "setup-lane.sh ships to the region this creates the group in (not the host's own region)"
  }
  assert {
    condition     = output.broker_role_arn == "arn:aws:iam::500268966557:role/agent-cred-broker"
    error_message = "the broker role is in the broker account"
  }
  assert {
    condition     = toset(jsondecode(file("${path.module}/../../allowlist.json")).accounts["805532413586"].regions) == toset(var.allowed_regions)
    error_message = "the role's regions match the allowlist's"
  }
}
