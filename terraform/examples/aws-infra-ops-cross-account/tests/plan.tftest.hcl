# Plans the operator role without cloud credentials.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/layered-infra-ops" }
  }
}

variables {
  account_id        = "111111111111"
  trusted_role_arns = ["arn:aws:iam::222222222222:role/example-operator-admin"]
}

run "trusts_only_the_named_role" {
  command = plan
  assert {
    condition     = length(jsondecode(aws_iam_role.operator.assume_role_policy).Statement[0].Principal.AWS) == 1 && jsondecode(aws_iam_role.operator.assume_role_policy).Statement[0].Principal.AWS[0] == "arn:aws:iam::222222222222:role/example-operator-admin"
    error_message = "The trust names exactly the given role ARNs."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role.operator.assume_role_policy).Statement) == 1 && !strcontains(aws_iam_role.operator.assume_role_policy, ":root") && !strcontains(aws_iam_role.operator.assume_role_policy, "*")
    error_message = "No account root, no wildcard, one statement."
  }
  assert {
    condition     = !contains(keys(jsondecode(aws_iam_role.operator.assume_role_policy).Statement[0]), "Condition")
    error_message = "Without external_id the trust carries no condition."
  }
}

run "admin_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy_attachment.operator) == 1 && contains(keys(aws_iam_role_policy_attachment.operator), "arn:aws:iam::aws:policy/AdministratorAccess")
    error_message = "The default grant is AdministratorAccess and nothing else."
  }
  assert {
    condition     = aws_iam_role.operator.max_session_duration == 3600 && aws_iam_role.operator.name == "layered-infra-ops"
    error_message = "One-hour sessions and the default name."
  }
}

run "external_id_guards_the_assume" {
  command = plan
  variables {
    external_id = "example-guard"
  }
  assert {
    condition     = jsondecode(aws_iam_role.operator.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "example-guard"
    error_message = "external_id becomes an sts:ExternalId condition."
  }
}

run "refuses_an_account_root" {
  command = plan
  variables {
    trusted_role_arns = ["arn:aws:iam::222222222222:root"]
  }
  expect_failures = [var.trusted_role_arns]
}

run "refuses_a_wildcard" {
  command = plan
  variables {
    trusted_role_arns = ["arn:aws:iam::222222222222:role/*"]
  }
  expect_failures = [var.trusted_role_arns]
}

run "refuses_a_session_over_twelve_hours" {
  command = plan
  variables {
    max_session_duration = 43201
  }
  expect_failures = [var.max_session_duration]
}
