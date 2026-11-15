# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {}

run "only_infra_ops_admin_may_assume" {
  command = plan
  assert {
    condition     = length(output.trust_policy.Statement) == 1
    error_message = "one trust statement"
  }
  assert {
    condition = (
      output.trust_policy.Statement[0].Principal.AWS == "arn:aws:iam::500268966557:root" &&
      output.trust_policy.Statement[0].Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::500268966557:role/layered-agent-admin-infra-ops-dev"
    )
    error_message = "trust pins aws:PrincipalArn to infra-ops' admin role"
  }
  assert {
    condition     = aws_iam_role.bootstrap.name == "layered-infra-ops-broker-tf" && aws_iam_role.bootstrap.max_session_duration == 3600
    error_message = "name and 1 h cap"
  }
}

run "manages_only_the_scoped_role_and_its_state" {
  command = plan
  assert {
    condition = alltrue([
      for s in output.permissions_policy.Statement : s.Effect == "Deny" || contains([
        "arn:aws:iam::805532413586:role/agent-broker-sandbox-scoped",
        "arn:aws:s3:::agent-cred-broker-tfstate-805532413586",
        "arn:aws:s3:::agent-cred-broker-tfstate-805532413586/aws-cred-broker/*",
      ], s.Resource)
    ])
    error_message = "every allow names the scoped role, the bucket or the state prefix: no wildcard resource"
  }
  assert {
    condition = alltrue([
      for s in output.permissions_policy.Statement : s.Effect == "Deny" || alltrue([for a in s.Action : can(regex("^(iam|s3):[A-Za-z]+$", a))])
    ])
    error_message = "IAM and S3 actions only, none wildcarded"
  }
  assert {
    condition = alltrue([
      for s in output.permissions_policy.Statement : !contains(s.Action, "iam:PassRole") && !contains(s.Action, "iam:PutRolePermissionsBoundary") && !contains(s.Action, "iam:CreatePolicy")
    ])
    error_message = "no PassRole, boundary changes or new managed policies"
  }
  assert {
    condition = (
      contains(output.permissions_policy.Statement[1].Action, "iam:AttachRolePolicy") &&
      output.permissions_policy.Statement[1].Condition.ArnEquals["iam:PolicyARN"] == "arn:aws:iam::aws:policy/PowerUserAccess"
    )
    error_message = "attach only PowerUserAccess"
  }
  assert {
    condition     = output.permissions_policy.Statement[3].Condition.StringLike["s3:prefix"] == ["aws-cred-broker/*"]
    error_message = "list only the state prefix"
  }
}

run "state_bucket_is_private_versioned_encrypted_tls_only" {
  command = plan
  assert {
    condition     = aws_s3_bucket.state.bucket == "agent-cred-broker-tfstate-805532413586"
    error_message = "bucket name"
  }
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "versioned"
  }
  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.state.rule : one(r.apply_server_side_encryption_by_default).sse_algorithm]) == "AES256"
    error_message = "encrypted at rest"
  }
  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "every public access block on"
  }
  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs disabled"
  }
  assert {
    condition = (
      output.bucket_policy.Statement[0].Condition.Bool["aws:SecureTransport"] == "false" &&
      output.bucket_policy.Statement[1].Condition.StringNotEquals["aws:PrincipalAccount"] == "805532413586"
    )
    error_message = "TLS only and this account only"
  }
}

run "refuses_a_wildcard_admin_role" {
  command = plan
  variables {
    infra_ops_admin_role_arn = "arn:aws:iam::500268966557:role/*"
  }
  expect_failures = [var.infra_ops_admin_role_arn]
}
