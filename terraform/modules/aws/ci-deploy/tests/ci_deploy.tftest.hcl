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
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::env-deploy-111111111111", region = "us-west-2" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  name                      = "env-deploy"
  cluster_name              = "env"
  cluster_security_group_id = "sg-cluster"
  vpc_id                    = "vpc-1"
  subnet_ids                = ["subnet-a", "subnet-b"]
  kms_key_arn               = "arn:aws:kms:us-west-2:111111111111:key/k"
  github_repository         = "example/ops"
  apply_environment         = "env-prod"
  namespaces                = ["agent-relay"]
}

run "defaults" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "The OIDC provider is created by default."
  }
  assert {
    condition     = aws_codebuild_project.this["plan"].concurrent_build_limit == 1 && aws_codebuild_project.this["apply"].concurrent_build_limit == 1
    error_message = "One build at a time per project."
  }
  assert {
    condition     = one(aws_codebuild_project.this["apply"].environment).privileged_mode == false
    error_message = "No privileged builds."
  }
  assert {
    condition     = length(one(aws_codebuild_project.this["plan"].vpc_config).subnets) == 2
    error_message = "Builds run in the given private subnets."
  }
  assert {
    condition     = aws_eks_access_policy_association.plan_view.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "plan gets the namespaced view policy only."
  }
  assert {
    condition     = one(aws_eks_access_policy_association.plan_view.access_scope).type == "namespace"
    error_message = "plan access is namespace scoped."
  }
  assert {
    condition     = aws_eks_access_entry.build["plan"].kubernetes_groups == toset(["env-deploy-plan"])
    error_message = "plan is in the group the RBAC manifest binds."
  }
  assert {
    condition     = strcontains(output.plan_rbac_manifest, "secrets") && strcontains(output.plan_rbac_manifest, "env-deploy-plan")
    error_message = "The plan RBAC manifest grants Secrets read to the plan group."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_api.from_port == 443 && aws_vpc_security_group_ingress_rule.cluster_api.security_group_id == "sg-cluster"
    error_message = "Builds reach the cluster API on 443."
  }
  assert {
    condition     = tolist(local.plan_subjects) == tolist(["repo:example/ops:ref:refs/heads/main"])
    error_message = "plan defaults to the main branch."
  }
  assert {
    condition     = local.apply_subject == "repo:example/ops:environment:env-prod"
    error_message = "apply is trusted only for the approval environment."
  }
}

run "pull_request_plan_refused" {
  command = plan
  variables {
    plan_subjects = ["repo:example/ops:pull_request"]
  }
  expect_failures = [terraform_data.guard]
}

run "existing_oidc_provider" {
  command = plan
  variables {
    create_github_oidc_provider = false
    github_oidc_provider_arn    = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "No second provider."
  }
}

run "existing_oidc_provider_requires_arn" {
  command = plan
  variables {
    create_github_oidc_provider = false
  }
  expect_failures = [terraform_data.guard]
}
