locals {
  bucket_arn  = module.artifacts.bucket_arn
  project_arn = { for m in keys(local.modes) : m => "arn:${local.partition}:codebuild:${local.region}:${local.account}:project/${var.name}-${m}" }
  log_arn     = "arn:${local.partition}:logs:${local.region}:${local.account}:log-group:${local.log_group}"
  subnet_arns = [for s in var.subnet_ids : "arn:${local.partition}:ec2:${local.region}:${local.account}:subnet/${s}"]
}

# ---- Roles GitHub assumes (OIDC). They can only hand a bundle to their own CodeBuild project and read its report.

data "aws_iam_policy_document" "trigger_trust" {
  for_each = local.modes
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.subjects
    }
  }
}

resource "aws_iam_role" "trigger" {
  for_each             = local.modes
  name                 = "${var.name}-github-${each.key}"
  description          = "GitHub ${var.github_repository}: start the ${each.key} build for ${var.cluster_name}."
  assume_role_policy   = data.aws_iam_policy_document.trigger_trust[each.key].json
  max_session_duration = 7200
  tags                 = local.tags
  depends_on           = [terraform_data.guard]
}

data "aws_iam_policy_document" "trigger" {
  for_each = local.modes
  statement {
    sid       = "StartOwnProject"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StopBuild"]
    resources = [local.project_arn[each.key]]
  }
  statement {
    sid       = "ReadOwnLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["${local.log_arn}:log-stream:${each.key}/*"]
  }
  statement {
    sid       = "UploadBundle"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/${each.value.bundle_prefix}*"]
  }
  statement {
    sid       = "ReadOwnReports"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/runs/*/${each.key}/*"]
  }
  statement {
    sid       = "ListOwnReports"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["runs/*/${each.key}/*"]
    }
  }
  statement {
    sid       = "ArtifactKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "trigger" {
  for_each = local.modes
  name     = "start-${each.key}"
  role     = aws_iam_role.trigger[each.key].id
  policy   = data.aws_iam_policy_document.trigger[each.key].json
}

# ---- CodeBuild service roles: what the job itself can do. Kubernetes rights come from eks.tf access entries.

data "aws_iam_policy_document" "build_trust" {
  for_each = local.modes
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.project_arn[each.key]]
    }
  }
}

resource "aws_iam_role" "build" {
  for_each           = local.modes
  name               = "${var.name}-build-${each.key}"
  description        = "CodeBuild ${each.key} job for ${var.cluster_name}."
  assume_role_policy = data.aws_iam_policy_document.build_trust[each.key].json
  tags               = local.tags
}

data "aws_iam_policy_document" "build" {
  for_each = local.modes
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_arn}:*"]
  }
  statement {
    sid       = "Bundle"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/${each.value.bundle_prefix}*"]
  }
  statement {
    sid       = "Report"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/runs/*"]
  }
  statement {
    sid       = "ArtifactKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "Cluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account}:cluster/${var.cluster_name}"]
  }
  # VPC builds: CodeBuild attaches an ENI in the configured subnets.
  statement {
    sid = "VpcDescribe"
    actions = [
      "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface", "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "VpcEni"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account}:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = local.subnet_arns
    }
  }
  dynamic "statement" {
    for_each = each.key == "apply" ? [1] : []
    content {
      sid       = "Snapshots"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arn}/snapshots/*"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "apply" && length(var.rds_instance_identifiers) > 0 ? [1] : []
    content {
      sid     = "RdsSnapshot"
      actions = ["rds:CreateDBSnapshot", "rds:AddTagsToResource", "rds:DescribeDBSnapshots"]
      resources = concat(
        [for id in var.rds_instance_identifiers : "arn:${local.partition}:rds:${local.region}:${local.account}:db:${id}"],
        ["arn:${local.partition}:rds:${local.region}:${local.account}:snapshot:${var.name}-*"],
      )
    }
  }
  dynamic "statement" {
    for_each = each.key == "apply" && length(var.rds_instance_identifiers) > 0 ? [1] : []
    content {
      sid       = "RdsDescribe"
      actions   = ["rds:DescribeDBInstances"]
      resources = [for id in var.rds_instance_identifiers : "arn:${local.partition}:rds:${local.region}:${local.account}:db:${id}"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "apply" && var.secrets_manager_prefix != null ? [1] : []
    content {
      sid = "DeploySecrets"
      actions = [
        "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:CreateSecret",
        "secretsmanager:TagResource",
      ]
      resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account}:secret:${coalesce(var.secrets_manager_prefix, "none/")}*"]
    }
  }
}

resource "aws_iam_role_policy" "build" {
  #checkov:skip=CKV_AWS_290:ENI describe/create for VPC builds has no resource-level scoping; CreateNetworkInterfacePermission is scoped by subnet and service.
  #checkov:skip=CKV_AWS_355:Same: the ec2 Describe actions do not support resource-level permissions.
  for_each = local.modes
  name     = "build-${each.key}"
  role     = aws_iam_role.build[each.key].id
  policy   = data.aws_iam_policy_document.build[each.key].json
}
