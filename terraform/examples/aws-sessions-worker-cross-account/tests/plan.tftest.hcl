# Plans the cross-account worker role without cloud credentials.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-sessions-worker" }
  }
}

variables {
  account_id           = "111111111111"
  region               = "us-west-2"
  eks_cluster_name     = "relay"
  namespace            = "relay-prod"
  role_name            = "relay-prod-sessions-worker"
  sessions_bucket_arn  = "arn:aws:s3:::sessions-bucket"
  sessions_kms_key_arn = "arn:aws:kms:us-east-1:222222222222:key/00000000-0000-4000-8000-000000000000"
}

run "least_privilege" {
  command = plan
  assert {
    condition     = aws_eks_pod_identity_association.worker.service_account == "agent-relay-worker" && aws_eks_pod_identity_association.worker.namespace == "relay-prod"
    error_message = "The association binds the release's worker ServiceAccount."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.worker.policy).Statement :
    !contains(flatten([s.Action]), "s3:DeleteObject") && !contains(flatten([s.Action]), "s3:DeleteObjectVersion") && !contains(flatten([s.Action]), "s3:*")])
    error_message = "The worker never deletes."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.worker.policy).Statement :
    s.Sid == "WriteEncryptedSummaries" && s.Resource == "arn:aws:s3:::sessions-bucket/96bulls/*/v1/*/summary/*"])
    error_message = "Writes are limited to summary objects."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.worker.policy).Statement :
    s.Sid == "SessionsKeyViaS3" && try(s.Condition.StringEquals["kms:ViaService"], "") == "s3.us-east-1.amazonaws.com"])
    error_message = "The key is used through S3 in the key's region only."
  }
  assert {
    condition     = jsondecode(aws_iam_role.worker.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-arn"] == "arn:aws:eks:us-west-2:111111111111:cluster/relay"
    error_message = "Only the named cluster in this account and Region may assume the role."
  }
  assert {
    condition     = jsondecode(aws_iam_role.worker.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "agent-relay-worker"
    error_message = "Only the worker ServiceAccount may assume the role."
  }
}

run "refuses_a_key_path_as_bucket" {
  command = plan
  variables {
    sessions_bucket_arn = "arn:aws:s3:::sessions-bucket/96bulls"
  }
  expect_failures = [var.sessions_bucket_arn]
}

run "refuses_the_default_service_account" {
  command = plan
  variables {
    service_account = "default"
  }
  expect_failures = [var.service_account]
}
