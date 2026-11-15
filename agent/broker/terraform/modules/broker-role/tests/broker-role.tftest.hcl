# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {}

variables {
  account_id             = "111122223333"
  trusted_principal_arns = ["arn:aws:iam::111122223333:role/layered-agent-infra-ops-dev"]
  target_role_arns       = ["arn:aws:iam::805532413586:role/agent-broker-sandbox-scoped"]
}

run "trusts_only_the_exact_host_role" {
  command = plan
  assert {
    condition     = length(output.trust_policy.Statement) == 1
    error_message = "one trust statement"
  }
  assert {
    condition     = output.trust_policy.Statement[0].Principal.AWS == "arn:aws:iam::111122223333:root" && output.trust_policy.Statement[0].Condition.ArnEquals["aws:PrincipalArn"] == var.trusted_principal_arns
    error_message = "trust must pin aws:PrincipalArn to the host role"
  }
  assert {
    condition     = aws_iam_role.broker.assume_role_policy == jsonencode(output.trust_policy) && aws_iam_role.broker.max_session_duration == 3600
    error_message = "the role carries the reviewed trust policy and a one-hour cap"
  }
}

run "may_only_vend_into_target_roles" {
  command = plan
  assert {
    condition     = length(output.permissions_policy.Statement) == 1 && output.permissions_policy.Statement[0].Effect == "Allow"
    error_message = "one allow statement"
  }
  assert {
    condition     = toset(output.permissions_policy.Statement[0].Action) == toset(["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"])
    error_message = "only AssumeRole, TagSession and SetSourceIdentity"
  }
  assert {
    condition     = output.permissions_policy.Statement[0].Resource == var.target_role_arns
    error_message = "only on the listed target roles"
  }
}

run "rejects_a_wildcard_principal" {
  command = plan
  variables {
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/*"]
  }
  expect_failures = [var.trusted_principal_arns]
}

run "rejects_a_wildcard_target" {
  command = plan
  variables {
    target_role_arns = ["arn:aws:iam::805532413586:role/*"]
  }
  expect_failures = [var.target_role_arns]
}
