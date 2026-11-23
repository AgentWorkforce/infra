mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-session-analysis" }
  }
}

variables {
  account_id           = "111111111111"
  region               = "us-west-2"
  eks_cluster_name     = "relay"
  namespace            = "relay-prod"
  role_name            = "relay-prod-session-analysis"
  sessions_bucket_arn  = "arn:aws:s3:::sessions-bucket"
  sessions_kms_key_arn = "arn:aws:kms:us-east-1:222222222222:key/00000000-0000-4000-8000-000000000000"
}

run "least_privilege" {
  command = plan

  assert {
    condition     = aws_eks_pod_identity_association.runner.service_account == "agent-relay-worker-session-analysis" && aws_eks_pod_identity_association.runner.namespace == "relay-prod"
    error_message = "The association must bind only the dedicated runner ServiceAccount."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.runner.policy).Statement :
      s.Sid == "WriteAnalysisResults" && s.Resource == "arn:aws:s3:::sessions-bucket/96bulls/*/v1/*/normalized/session-analysis-v2/*" &&
    alltrue([for a in ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"] : contains(flatten([s.Action]), a)])])
    error_message = "Result writes and deletes must be limited to session-analysis-v2 objects."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.runner.policy).Statement :
    s.Sid == "WriteAnalysisResults" || !contains(flatten([s.Action]), "s3:DeleteObject") && !contains(flatten([s.Action]), "s3:DeleteObjectVersion")])
    error_message = "No other statement may delete objects."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.runner.policy).Statement :
    s.Sid == "ListAnalysisResultVersions" && try(s.Condition.StringLike["s3:prefix"], "") == "96bulls/*/v1/*/normalized/session-analysis-v2/*"])
    error_message = "Version listing must be conditioned to result objects."
  }
  assert {
    condition = (anytrue([for s in jsondecode(aws_iam_role_policy.runner.policy).Statement :
      s.Sid == "InspectCanonicalBucket" && contains(flatten([s.Action]), "s3:GetBucketVersioning")]) &&
      anytrue([for s in output.resource_policy_statements.bucket_policy :
    s.Sid == "SessionAnalysisInspectsBucket" && contains(flatten([s.Action]), "s3:GetBucketVersioning")]))
    error_message = "Both accounts must allow the runner's startup bucket-versioning check."
  }
  assert {
    condition = (anytrue([for s in jsondecode(aws_iam_role_policy.runner.policy).Statement :
      s.Sid == "NoReservedNamespaces" && s.Effect == "Deny" && s.Resource == "arn:aws:s3:::sessions-bucket/96bulls/.*"]) &&
      anytrue([for s in jsondecode(aws_iam_role_policy.runner.policy).Statement :
    s.Sid == "NoReservedNamespaceDecrypt" && s.Effect == "Deny" && s.Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] == "arn:aws:s3:::sessions-bucket/96bulls/.*"]))
    error_message = "The runner must neither read nor decrypt any reserved dot-prefix namespace."
  }
  assert {
    condition = (anytrue([for s in output.resource_policy_statements.key_policy :
      s.Sid == "SessionAnalysisDecryptsViaS3" && s.Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] == "arn:aws:s3:::sessions-bucket/96bulls/*/v1/*"]) &&
      anytrue([for s in output.resource_policy_statements.key_policy :
    s.Sid == "SessionAnalysisEncryptsViaS3" && s.Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] == "arn:aws:s3:::sessions-bucket/96bulls/*/v1/*/normalized/session-analysis-v2/*"]))
    error_message = "KMS grants must use the exact object-ARN encryption contexts; never admit the bucket ARN used by S3 Bucket Keys."
  }
  assert {
    condition = alltrue([for s in output.resource_policy_statements.key_policy :
    s.Condition.StringEquals["kms:ViaService"] == "s3.us-east-1.amazonaws.com" && s.Condition.StringEquals["kms:CallerAccount"] == "111111111111"])
    error_message = "Cross-account KMS grants must bind the cluster account and bucket-region S3 service."
  }
  assert {
    condition     = jsondecode(aws_iam_role.runner.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "agent-relay-worker-session-analysis"
    error_message = "Only the dedicated ServiceAccount may assume the role."
  }
}

run "refuses_shared_service_accounts" {
  command = plan
  variables { service_account = "agent-relay-worker" }
  expect_failures = [var.service_account]
}

run "refuses_session_ingest_service_account" {
  command = plan
  variables { service_account = "agent-relay-session-ingest-api" }
  expect_failures = [var.service_account]
}

run "refuses_alleyoop_service_account" {
  command = plan
  variables { service_account = "agent-relay-alleyoop" }
  expect_failures = [var.service_account]
}

run "refuses_a_key_path_as_bucket" {
  command = plan
  variables { sessions_bucket_arn = "arn:aws:s3:::sessions-bucket/96bulls" }
  expect_failures = [var.sessions_bucket_arn]
}

run "accepts_a_multi_region_key" {
  command = plan
  variables {
    sessions_kms_key_arn = "arn:aws:kms:eu-west-1:222222222222:key/mrk-0123456789abcdef0123456789abcdef"
  }
  assert {
    condition = alltrue([for s in output.resource_policy_statements.key_policy :
    s.Condition.StringEquals["kms:ViaService"] == "s3.eu-west-1.amazonaws.com"])
    error_message = "The key must be used through S3 in its own Region."
  }
}
