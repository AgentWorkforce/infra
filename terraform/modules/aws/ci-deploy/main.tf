data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  bucket    = "${var.name}-${local.account}"
  log_group = "/codebuild/${var.name}"

  # The placeholder only lets the plan reach terraform_data.guard, which names the missing input.
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : coalesce(var.github_oidc_provider_arn, "missing-github_oidc_provider_arn")
  plan_subjects     = var.plan_subjects != null ? var.plan_subjects : ["repo:${var.github_repository}:ref:refs/heads/main"]
  apply_subject     = "repo:${var.github_repository}:environment:${var.apply_environment}"

  # plan: read the live release and write its report. apply: also snapshot and upgrade.
  modes = {
    plan  = { subjects = local.plan_subjects, bundle_prefix = "plan-bundles/" }
    apply = { subjects = [local.apply_subject], bundle_prefix = "apply-bundles/" }
  }
  tags = merge(var.tags, { "agent-relay/component" = "ci-deploy" })
}

resource "terraform_data" "guard" {
  lifecycle {
    precondition {
      condition     = var.create_github_oidc_provider || var.github_oidc_provider_arn != null
      error_message = "Pass github_oidc_provider_arn when create_github_oidc_provider is false."
    }
    precondition {
      condition     = alltrue([for s in local.plan_subjects : !strcontains(s, ":pull_request")])
      error_message = "plan_subjects must not include pull_request: a pull request would run its own code with the plan job's read access."
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.tags
}

module "artifacts" {
  source      = "../object-storage"
  bucket_name = local.bucket
  kms_key_arn = var.kms_key_arn
  lifecycle_rules = [
    { id = "plan-bundles", prefix = "plan-bundles/", expiration_days = var.artifact_retention_days },
    { id = "apply-bundles", prefix = "apply-bundles/", expiration_days = var.artifact_retention_days },
    { id = "runs", prefix = "runs/", expiration_days = var.artifact_retention_days },
    { id = "snapshots", prefix = "snapshots/", expiration_days = var.snapshot_retention_days },
  ]
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "builds" {
  #checkov:skip=CKV_AWS_158:A customer managed key is optional (log_kms_key_arn); its key policy must name this log group. Build logs never contain secret values.
  name              = local.log_group
  retention_in_days = 365
  kms_key_id        = var.log_kms_key_arn
  tags              = local.tags
}

resource "aws_security_group" "builds" {
  name        = "${var.name}-builds"
  description = "CodeBuild deploy jobs: egress only (cluster API, registries, AWS APIs, databases)."
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_egress_rule" "builds" {
  #checkov:skip=CKV_AWS_382:The jobs fetch helm/kubectl releases and chart dependencies from the internet through NAT and reach managed databases; there is no ingress.
  security_group_id = aws_security_group.builds.id
  description       = "All egress through the VPC's NAT and endpoints."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_api" {
  security_group_id            = var.cluster_security_group_id
  description                  = "${var.name}: CodeBuild deploy jobs to the private EKS API"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.builds.id
}
