# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {}

variables {
  broker_role_arn = "arn:aws:iam::111122223333:role/agent-cred-broker"
}

run "trusts_only_the_broker_with_request_tags_and_source_identity" {
  command = plan
  assert {
    condition     = alltrue([for s in output.trust_policy.Statement : s.Principal.AWS == var.broker_role_arn && s.Effect == "Allow"])
    error_message = "every trust statement names only the broker role"
  }
  assert {
    condition     = output.trust_policy.Statement[0].Condition.Null == { "aws:RequestTag/agent-run" = "false", "aws:RequestTag/agent-ns" = "false", "aws:RequestTag/agent" = "false", "sts:SourceIdentity" = "false" }
    error_message = "AssumeRole requires the run tag, namespace tag, agent tag and a source identity"
  }
  assert {
    condition     = output.trust_policy.Statement[0].Condition.StringLike["aws:RequestTag/broker-request-id"] == "cb-*"
    error_message = "AssumeRole requires a broker request id"
  }
  assert {
    condition     = output.trust_policy.Statement[1].Action == "sts:TagSession" && output.trust_policy.Statement[1].Condition["ForAllValues:StringEquals"]["aws:TagKeys"] == ["broker-request-id", "agent-run", "agent-ns", "agent"]
    error_message = "only the four broker session tags"
  }
  assert {
    condition     = aws_iam_role.scoped.assume_role_policy == jsonencode(output.trust_policy) && aws_iam_role.scoped.max_session_duration == 3600
    error_message = "the role carries the reviewed trust policy and a one-hour cap"
  }
}

run "ceiling_denies_identity_untagged_foreign_and_retagging" {
  command = plan
  assert {
    condition     = alltrue([for s in output.ceiling_policy.Statement : s.Effect == "Deny"])
    error_message = "the ceiling is denies only"
  }
  assert {
    condition     = length(setintersection(toset(output.ceiling_by_sid["DenyIdentityAccountAndAuditControl"].Action), toset(["iam:*", "sts:*", "organizations:*", "account:*", "identitystore:*", "cloudtrail:*"]))) == 6
    error_message = "no IAM, STS, org, account, identity or audit control"
  }
  assert {
    condition     = output.ceiling_by_sid["DenySessionsWithoutRunTag"].Condition.Null["aws:PrincipalTag/agent-run"] == "true"
    error_message = "a session without the run tag can do nothing"
  }
  assert {
    condition     = output.ceiling_by_sid["DenyCreatingWithAnotherRunsTag"].Condition.StringNotEquals["aws:RequestTag/agent-run"] == "$${aws:PrincipalTag/agent-run}"
    error_message = "nothing created with another run's tag"
  }
  assert {
    condition     = contains(output.ceiling_by_sid["DenyRemovingTheRunTag"].Action, "sqs:UntagQueue") && !contains(output.ceiling_by_sid["DenyRemovingTheRunTag"].Action, "sqs:TagQueue")
    error_message = "the run tag can never be removed; adding it is handled by name"
  }
  assert {
    condition     = contains(output.ceiling_by_sid["DenyRunTagOnResourcesNotNamedForTheRun"].Action, "sqs:TagQueue") && contains(output.ceiling_by_sid["DenyRunTagOnResourcesNotNamedForTheRun"].NotResource, "arn:aws:sqs:*:*:$${aws:PrincipalTag/agent-ns}--*")
    error_message = "tag-on-create only on resources named <the run's broker-assigned namespace>--…"
  }
  assert {
    condition     = alltrue([for r in output.ceiling_by_sid["DenyRunTagOnResourcesNotNamedForTheRun"].NotResource : endswith(r, "$${aws:PrincipalTag/agent-ns}--*")])
    error_message = "every run-owned name uses the -- separator, so no run's names overlap another's"
  }
  assert {
    condition = (
      contains(output.ceiling_by_sid["DenyOverwritingAnotherRunsTag"].Action, "sqs:TagQueue") &&
      contains(output.ceiling_by_sid["DenyOverwritingAnotherRunsTag"].Action, "ec2:CreateTags") &&
      output.ceiling_by_sid["DenyOverwritingAnotherRunsTag"].Condition.StringNotEquals["aws:ResourceTag/agent-run"] == "$${aws:PrincipalTag/agent-run}" &&
      output.ceiling_by_sid["DenyOverwritingAnotherRunsTag"].Condition.Null["aws:ResourceTag/agent-run"] == "false"
    )
    error_message = "a resource already carrying another run's tag can't be re-tagged"
  }
  assert {
    condition     = output.ceiling_by_sid["DenyStopAndDeleteOutsideOwnRun"].Condition.StringNotEquals["aws:ResourceTag/agent-run"] == "$${aws:PrincipalTag/agent-run}" && contains(output.ceiling_by_sid["DenyStopAndDeleteOutsideOwnRun"].Action, "ec2:TerminateInstances")
    error_message = "stop and delete only on the session's own run"
  }
  assert {
    condition     = output.ceiling_by_sid["DenyOutsideAllowedRegions"].Condition.StringNotEquals["aws:RequestedRegion"] == var.allowed_regions
    error_message = "allowed regions only"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.base.policy_arn == "arn:aws:iam::aws:policy/PowerUserAccess"
    error_message = "the base is PowerUserAccess, which has no IAM"
  }
}

run "rejects_a_wildcard_broker" {
  command = plan
  variables {
    broker_role_arn = "arn:aws:iam::111122223333:role/*"
  }
  expect_failures = [var.broker_role_arn]
}
