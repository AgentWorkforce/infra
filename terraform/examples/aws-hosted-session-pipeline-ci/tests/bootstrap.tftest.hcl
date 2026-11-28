mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  }
}

variables {
  account_id = "111111111111"
  region     = "us-east-1"
  pipeline = {
    name_prefix   = "96bulls-test"
    function_name = "96bulls-test-session-pipeline"
    role_name     = "96bulls-test-session-pipeline-role"
    bucket_name   = "test-transcripts"
    kms_key_arn   = "arn:aws:kms:us-east-1:111111111111:key/11111111-1111-1111-1111-111111111111"
    secret_name   = "96bulls/test/session-pipeline"
  }
}

run "roles_are_scoped" {
  command = apply

  assert {
    condition     = toset(keys(aws_iam_role.ci)) == toset(["plan", "apply"])
    error_message = "Two roles: plan and apply."
  }
  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.ci["plan"].policy).Statement : s.Sid], "NeverWriteState") && !contains([for s in jsondecode(aws_iam_role_policy.ci["plan"].policy).Statement : s.Sid], "WriteState")
    error_message = "The plan role never writes state and gets no write grants."
  }
  assert {
    condition     = alltrue([for k in ["plan", "apply"] : contains([for s in jsondecode(aws_iam_role_policy.ci[k].policy).Statement : s.Sid if s.Effect == "Deny"], "NoSecretValues")])
    error_message = "Neither role can read a secret value."
  }
  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.ci["apply"].policy).Statement : s.Sid if s.Effect == "Deny"], "NoDeletes")
    error_message = "The apply role cannot delete what the root owns."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.ci["apply"].policy).Statement : s.Effect == "Deny" || s.Resource != "*" if s.Sid != "Identity" && s.Sid != "ReadMappings" && s.Sid != "ReadAlarms" && s.Sid != "ReadLogs"])
    error_message = "Every allow except the list-style reads is resource-scoped."
  }
  assert {
    condition     = aws_s3_bucket.state.bucket == "hosted-session-pipeline-ci-111111111111-us-east-1" && aws_ssm_parameter.tfvars.type == "SecureString"
    error_message = "State bucket and SecureString parameter."
  }
}
