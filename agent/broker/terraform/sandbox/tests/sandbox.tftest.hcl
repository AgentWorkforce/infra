# Plan-only, mocked providers: no AWS credentials, no state, no apply.
mock_provider "aws" {
  alias = "broker"
  override_resource {
    target          = module.broker_role.aws_iam_role.broker
    override_during = plan
    values          = { arn = "arn:aws:iam::111122223333:role/agent-cred-broker" }
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
  broker_account_id    = "111122223333"
  broker_host_role_arn = "arn:aws:iam::111122223333:role/layered-agent-infra-ops-dev"
}

run "wires_broker_to_scoped_role_and_matches_the_allowlist" {
  command = plan
  assert {
    condition     = output.sandbox_scoped_role_arn == jsondecode(file("${path.module}/../../allowlist.json")).accounts["805532413586"].roles.scoped
    error_message = "the allowlist's scoped role is the one this creates"
  }
  assert {
    condition     = output.broker_role_arn == "arn:aws:iam::111122223333:role/agent-cred-broker"
    error_message = "the broker role is in the broker account"
  }
  assert {
    condition     = toset(jsondecode(file("${path.module}/../../allowlist.json")).accounts["805532413586"].regions) == toset(var.allowed_regions)
    error_message = "the role's regions match the allowlist's"
  }
}
