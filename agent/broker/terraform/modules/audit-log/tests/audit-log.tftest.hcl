# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {}

run "the_audit_group_matches_the_host_and_keeps_two_years" {
  command = plan
  assert {
    condition     = aws_cloudwatch_log_group.audit.name == "/aws-cred-broker/audit"
    error_message = "the group setup-lane.sh ships to"
  }
  assert {
    condition     = aws_cloudwatch_log_group.audit.retention_in_days == 731
    error_message = "two years of retention"
  }
  assert {
    condition     = strcontains(file("${path.module}/../../../../setup-lane.sh"), "BROKER_AUDIT_LOG_GROUP=${aws_cloudwatch_log_group.audit.name}\n")
    error_message = "setup-lane.sh names the same group"
  }
}

run "rejects_a_group_outside_the_protected_prefix" {
  command = plan
  variables {
    name = "/somewhere/else"
  }
  expect_failures = [var.name]
}

run "rejects_short_retention" {
  command = plan
  variables {
    retention_in_days = 30
  }
  expect_failures = [var.retention_in_days]
}
