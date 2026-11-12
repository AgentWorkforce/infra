mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111111111111:policy/mock" }
  }
}

variables {
  name                     = "env-data"
  github_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  oidc_subject_prefix      = "repo:example@1/ops@2"
  workflow                 = "example/ops/.github/workflows/env-data.yml"
  apply_environment        = "env-prod"
  state = {
    bucket      = "env-tfstate-111111111111"
    key         = "agent-relay/111111111111/us-west-2/prod/data.tfstate"
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/state"
  }
  plan_store_prefix     = "ci-plans/111111111111/us-west-2/prod/data"
  tfvars_parameter_name = "/env-prod/ci-terraform/data-tfvars"
  stack = {
    name             = "agent-relay-prod"
    environment      = "prod"
    eks_cluster_name = "agent-relay-prod"
    kms_key_arn      = "arn:aws:kms:us-west-2:111111111111:key/env"
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = toset(keys(aws_iam_policy.this)) == toset(["read", "plan", "apply-state", "apply-identity", "apply-data"])
    error_message = "Pipeline and chief node permissions are off by default."
  }
  assert {
    condition     = toset(keys(aws_iam_role_policy_attachment.this)) == toset(["plan/read", "plan/plan", "apply/read", "apply/apply-state", "apply/apply-identity", "apply/apply-data"])
    error_message = "plan gets read + plan only; apply gets read + its own policies."
  }
  assert {
    condition     = alltrue([for k, v in aws_iam_policy.this : length(v.policy) <= 6144])
    error_message = "Every managed policy fits the 6,144-character limit."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.policies["plan"]).Statement : s.Effect == "Deny" || alltrue([
      for a in flatten([s.Action]) : contains(["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "kms:Decrypt", "kms:GenerateDataKey", "ssm:GetParameter"], a)
    ])])
    error_message = "The plan policy holds state reads, the lock, the plan store and tfvars only."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.policies["plan"]).Statement :
      !(s.Effect == "Allow" && contains(flatten([s.Action]), "s3:PutObject")) ||
      alltrue([for r in flatten([s.Resource]) : endswith(r, ".tflock") || endswith(r, "/run.tgz") || endswith(r, "/manifest.json")])
    ])
    error_message = "The plan role writes only the lock and its saved plan, never the state."
  }
  assert {
    condition = alltrue([
      one([for s in jsondecode(output.policies["plan"]).Statement : s if s.Sid == "SavePlan"]).Condition.Null["s3:if-none-match"] == "false",
      one([for s in jsondecode(output.policies["apply-state"]).Statement : s if s.Sid == "RecordApply"]).Condition.Null["s3:if-none-match"] == "false",
    ])
    error_message = "Plan-store objects are create-only (If-None-Match), so a reviewed plan cannot be replaced."
  }
  assert {
    condition     = one([for s in jsondecode(output.policies["read"]).Statement : s if s.Sid == "StackBucketHead"]).Resource == "arn:aws:s3:::agent-relay-prod-*"
    error_message = "HeadBucket on the stack's buckets only."
  }
  assert {
    condition     = one([for s in jsondecode(output.policies["plan"]).Statement : s if s.Sid == "NeverWriteState"]).Resource == "arn:aws:s3:::env-tfstate-111111111111/agent-relay/111111111111/us-west-2/prod/data.tfstate"
    error_message = "The plan role is denied writes to the state object."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.policies["read"]).Statement : s.Effect == "Deny" || alltrue([
      for a in flatten([s.Action]) : length(regexall("^[a-z0-9]+:(Describe|Get|List)", a)) > 0
    ])])
    error_message = "The shared refresh policy allows only Describe/Get/List actions."
  }
  assert {
    condition     = !contains(flatten([for s in jsondecode(output.policies["read"]).Statement : s.Effect == "Allow" ? flatten([s.Action]) : []]), "s3:GetObject")
    error_message = "No object reads in the refresh policy."
  }
  assert {
    condition     = contains([for s in jsondecode(output.policies["read"]).Statement : s.Sid if s.Effect == "Deny"], "NoSecretValues")
    error_message = "Secret values are denied to both roles."
  }
  assert {
    condition     = one([for s in jsondecode(output.policies["apply-data"]).Statement : s if s.Sid == "StackBuckets"]).Resource == "arn:aws:s3:::agent-relay-prod-*"
    error_message = "Bucket writes are limited to the stack's names."
  }
  assert {
    condition     = one([for s in jsondecode(output.policies["apply-identity"]).Statement : s if s.Sid == "StackRoles"]).Resource == "arn:aws:iam::111111111111:role/agent-relay-prod-*"
    error_message = "IAM writes are limited to the stack's roles."
  }
  assert {
    condition     = !strcontains(join(" ", values(output.policies)), "iam:AttachRolePolicy")
    error_message = "No managed policy attachments."
  }
  assert {
    condition     = output.ci.plan_store.prefix == "ci-plans/111111111111/us-west-2/prod/data" && output.ci.approval_environment == "env-prod"
    error_message = "ci output carries the plan store and approval environment."
  }
}

run "trust" {
  command = plan

  assert {
    condition     = local.subjects.plan == "repo:example@1/ops@2:ref:refs/heads/main"
    error_message = "plan trusts the main branch."
  }
  assert {
    condition     = local.subjects.apply == "repo:example@1/ops@2:environment:env-prod"
    error_message = "apply trusts the approval environment."
  }
  assert {
    condition = alltrue([for k in ["plan", "apply"] : toset([for c in one(data.aws_iam_policy_document.trust[k].statement).condition : c.variable]) == toset([
      "token.actions.githubusercontent.com:aud", "token.actions.githubusercontent.com:sub",
    ])])
    error_message = "Trust uses only aud and sub, the GitHub claims AWS evaluates."
  }
}

run "pipeline" {
  command = plan
  variables {
    lambda_pipeline = true
  }
  assert {
    condition     = contains(keys(aws_iam_policy.this), "apply-pipeline")
    error_message = "The opt-in adds its policy."
  }
  assert {
    condition     = alltrue([for k, v in aws_iam_policy.this : length(v.policy) <= 6144])
    error_message = "Every managed policy fits the 6,144-character limit."
  }
  assert {
    condition     = one([for s in jsondecode(output.policies["apply-identity"]).Statement : s if s.Sid == "PassStackRoles"]).Condition.StringEquals["iam:PassedToService"] == ["pods.eks.amazonaws.com", "lambda.amazonaws.com"]
    error_message = "Stack roles pass to Pod Identity and, with the pipeline, Lambda only."
  }
}

run "bad_state_key" {
  command = plan
  variables {
    state = { bucket = "b", key = "/abs/x.tfstate", kms_key_arn = "k" }
  }
  expect_failures = [var.state]
}
