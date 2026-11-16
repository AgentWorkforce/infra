# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {}

variables {
  broker_role_arn = "arn:aws:iam::500268966557:role/agent-cred-broker"
}

run "trusts_only_the_broker_with_its_tags_and_source_identity" {
  command = plan
  assert {
    condition     = alltrue([for s in output.trust_policy.Statement : s.Principal.AWS == var.broker_role_arn && s.Effect == "Allow"])
    error_message = "every trust statement names only the broker role"
  }
  assert {
    condition     = output.trust_policy.Statement[0].Condition.Null == { "aws:RequestTag/agent-run" = "false", "aws:RequestTag/agent-ns" = "false", "aws:RequestTag/agent" = "false", "sts:SourceIdentity" = "false" }
    error_message = "AssumeRole requires the broker's tags and a source identity"
  }
  assert {
    condition     = aws_iam_role.elevated.name == "agent-broker-elevated" && aws_iam_role.elevated.max_session_duration == 3600
    error_message = "name and 1 h cap"
  }
}

run "ceiling_denies_identity_untagged_sessions_and_other_regions" {
  command = plan
  assert {
    condition     = length(setintersection(toset(output.ceiling_by_sid["DenyIdentityAccountAndAuditControl"].Action), toset(["iam:*", "sts:*", "organizations:*", "cloudtrail:*", "kms:PutKeyPolicy", "kms:CreateGrant"]))) == 6
    error_message = "no IAM, STS, org, audit or key-policy control"
  }
  assert {
    condition     = output.ceiling_by_sid["DenySessionsWithoutBrokerTags"].Condition.Null["aws:PrincipalTag/broker-request-id"] == "true"
    error_message = "a session without the broker's request tag can do nothing"
  }
  assert {
    condition     = output.ceiling_by_sid["DenyOutsideAllowedRegions"].Condition.StringNotEquals["aws:RequestedRegion"] == var.allowed_regions
    error_message = "allowed regions only"
  }
}
