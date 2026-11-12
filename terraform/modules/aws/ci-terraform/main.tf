# GitHub OIDC roles that plan and apply one Terraform state (examples/aws-environments) straight from a
# GitHub-hosted job: the stack only calls AWS APIs, so no runner inside the VPC is needed. See
# docs/selfhost-ci-terraform.md and scripts/selfhost/ci-terraform.sh.
#
# plan : read the state (and take its lock), refresh every resource with read-only calls, save the plan to the
#        plan store. It cannot write the state or any stack resource.
# apply: apply one saved plan. It can write the state and create or change only resources named <stack>-*.
#
# Policies are built with jsonencode so tests can read them; each is a managed policy (6,144 characters max).
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  arn       = "arn:${local.partition}"
  stack     = var.stack.name

  state_bucket_arn = "${local.arn}:s3:::${var.state.bucket}"
  state_object_arn = "${local.state_bucket_arn}/${var.state.key}"
  lock_object_arn  = "${local.state_object_arn}.tflock"
  store_arn        = "${local.state_bucket_arn}/${var.plan_store_prefix}"
  tfvars_key_arn   = coalesce(var.tfvars_kms_key_arn, var.state.kms_key_arn)
  tfvars_arn       = "${local.arn}:ssm:${local.region}:${local.account}:parameter${var.tfvars_parameter_name}"
  public_params    = "${local.arn}:ssm:${local.region}::parameter/aws/service/*"

  subjects = {
    plan  = "${var.oidc_subject_prefix}:ref:refs/heads/${var.branch}"
    apply = "${var.oidc_subject_prefix}:environment:${var.apply_environment}"
  }
  tags = merge(var.tags, { "agent-relay/component" = "ci-terraform" })
}

# ---- Trust: aud and sub only, the GitHub claims AWS evaluates (ref, repository_id and job_workflow_ref are
# not condition keys). The repository's sub template carries its immutable owner and repository IDs.
# plan: jobs on branch. apply: jobs in apply_environment. GitHub environments for private repositories on the
# free plan have no reviewers, but they do have a deployment-branch policy: set apply_environment to deploy
# from branch only, and use it for this workflow alone, so its sub names this workflow's apply job and nothing else.

data "aws_iam_policy_document" "trust" {
  for_each = local.subjects
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each             = local.subjects
  name                 = "${var.name}-github-${each.key}"
  description          = "GitHub ${var.workflow}@${var.branch}: ${each.key} Terraform state s3://${var.state.bucket}/${var.state.key}."
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = var.max_session_duration
  tags                 = local.tags
}

# ---- Policies

locals {
  # Plan-store objects are written once (If-None-Match: *): a saved plan, its manifest and an apply claim can
  # never be replaced after review, not even by a later run of the same role.
  create_only = { Null = { "s3:if-none-match" = "false" } }
  state_kms = {
    Sid       = "StateKey"
    Effect    = "Allow"
    Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
    Resource  = var.state.kms_key_arn
    Condition = { StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" } }
  }
  tfvars = [
    { Sid = "Tfvars", Effect = "Allow", Action = "ssm:GetParameter", Resource = local.tfvars_arn },
    {
      Sid       = "TfvarsKey"
      Effect    = "Allow"
      Action    = "kms:Decrypt"
      Resource  = local.tfvars_key_arn
      Condition = { StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" } }
    },
  ]
  # HeadBucket (the wrapper's bucket-owner check) is s3:ListBucket with no prefix: it lists key names only.
  state_bucket = { Sid = "StateBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = local.state_bucket_arn }
  # S3 native locking (use_lockfile): a conditional put, then a delete, of <key>.tflock.
  state_lock = { Sid = "StateLock", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = local.lock_object_arn }

  # Read-only refresh of everything examples/aws-environments manages, for both roles. Bucket-level S3 reads
  # only; the denies keep object reads, secret values and other parameters out even if a wildcard grows.
  read_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Refresh"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "rds:Describe*", "rds:ListTagsForResource",
          "es:Describe*", "es:List*", "es:GetCompatibleVersions",
          "eks:DescribeCluster", "eks:DescribePodIdentityAssociation", "eks:ListPodIdentityAssociations", "eks:ListTagsForResource",
          "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags",
          "iam:GetInstanceProfile", "iam:ListInstanceProfilesForRole", "iam:GetPolicy", "iam:GetPolicyVersion",
          "iam:GetOpenIDConnectProvider",
          "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListResourceTags", "kms:GetPublicKey",
          "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetFunctionEventInvokeConfig", "lambda:GetPolicy",
          "lambda:GetEventSourceMapping", "lambda:ListEventSourceMappings", "lambda:ListTags", "lambda:ListVersionsByFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueueTags",
          "events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource",
          "logs:DescribeLogGroups", "logs:DescribeResourcePolicies", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
          "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
          "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy",
        ]
        Resource = "*"
      },
      {
        Sid    = "BucketSettings"
        Effect = "Allow"
        Action = [
          "s3:GetBucket*", "s3:GetAccelerateConfiguration", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration", "s3:GetIntelligentTieringConfiguration", "s3:GetAnalyticsConfiguration",
          "s3:GetInventoryConfiguration", "s3:GetMetricsConfiguration",
        ]
        Resource = "${local.arn}:s3:::*"
      },
      # HeadBucket (how the provider reads aws_s3_bucket) is s3:ListBucket; the stack's own buckets only.
      { Sid = "StackBucketHead", Effect = "Allow", Action = "s3:ListBucket", Resource = "${local.arn}:s3:::${local.stack}-*" },
      { Sid = "PublicParameters", Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = local.public_params },
      { Sid = "NoSecretValues", Effect = "Deny", Action = "secretsmanager:GetSecretValue", Resource = "*" },
      {
        Sid         = "NoOtherObjects"
        Effect      = "Deny"
        Action      = ["s3:GetObject", "s3:GetObjectVersion"]
        NotResource = [local.state_object_arn, local.lock_object_arn, "${local.store_arn}/*"]
      },
      {
        Sid         = "NoOtherParameters"
        Effect      = "Deny"
        Action      = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
        NotResource = [local.tfvars_arn, local.public_params]
      },
    ]
  }

  plan_policy = {
    Version = "2012-10-17"
    Statement = concat([
      local.state_bucket,
      { Sid = "StateRead", Effect = "Allow", Action = "s3:GetObject", Resource = local.state_object_arn },
      local.state_lock,
      local.state_kms,
      # Saved plans go to the state bucket (same key, same protection as the state they contain), never to GitHub.
      {
        Sid       = "SavePlan"
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = ["${local.store_arn}/*/run.tgz", "${local.store_arn}/*/manifest.json"]
        Condition = local.create_only
      },
      # Not even the lock-free variant: the plan role never writes the state.
      { Sid = "NeverWriteState", Effect = "Deny", Action = ["s3:PutObject", "s3:DeleteObject"], Resource = local.state_object_arn },
    ], local.tfvars)
  }

  apply_state_policy = {
    Version = "2012-10-17"
    Statement = concat([
      local.state_bucket,
      { Sid = "State", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = local.state_object_arn },
      local.state_lock,
      local.state_kms,
      { Sid = "ReadPlan", Effect = "Allow", Action = "s3:GetObject", Resource = "${local.store_arn}/*" },
      # Single use: apply-attempt.json is written with If-None-Match before Terraform runs.
      {
        Sid       = "RecordApply"
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = ["${local.store_arn}/*/apply-attempt.json", "${local.store_arn}/*/apply-result.json"]
        Condition = local.create_only
      },
    ], local.tfvars)
  }

  stack_role_arn = "${local.arn}:iam::${local.account}:role/${local.stack}-*"
  apply_identity_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StackRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        ]
        Resource = local.stack_role_arn
      },
      {
        Sid       = "PassStackRoles"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.stack_role_arn
        Condition = { StringEquals = { "iam:PassedToService" = concat(["pods.eks.amazonaws.com"], var.lambda_pipeline ? ["lambda.amazonaws.com"] : []) } }
      },
      {
        Sid       = "RdsServiceLinkedRole"
        Effect    = "Allow"
        Action    = "iam:CreateServiceLinkedRole"
        Resource  = "${local.arn}:iam::${local.account}:role/aws-service-role/rds.amazonaws.com/*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "rds.amazonaws.com" } }
      },
      {
        Sid      = "PodIdentity"
        Effect   = "Allow"
        Action   = ["eks:CreatePodIdentityAssociation", "eks:DeletePodIdentityAssociation", "eks:UpdatePodIdentityAssociation", "eks:TagResource", "eks:UntagResource"]
        Resource = ["${local.arn}:eks:${local.region}:${local.account}:cluster/${var.stack.eks_cluster_name}", "${local.arn}:eks:${local.region}:${local.account}:podidentityassociation/${var.stack.eks_cluster_name}/*"]
      },
      # Desktop-feed signing keys: the only keys the stack creates (Ed25519, tagged with the environment).
      {
        Sid      = "CreateSigningKeys"
        Effect   = "Allow"
        Action   = ["kms:CreateKey", "kms:TagResource"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/Environment" = var.stack.environment, "kms:KeySpec" = "ECC_NIST_EDWARDS25519" }
        }
      },
      {
        Sid    = "ManageSigningKeys"
        Effect = "Allow"
        Action = [
          "kms:PutKeyPolicy", "kms:UpdateKeyDescription", "kms:TagResource", "kms:UntagResource", "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
        ]
        Resource = "${local.arn}:kms:${local.region}:${local.account}:key/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Environment" = var.stack.environment, "kms:KeySpec" = "ECC_NIST_EDWARDS25519" }
        }
      },
      {
        Sid      = "SigningKeyAliases"
        Effect   = "Allow"
        Action   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
        Resource = "${local.arn}:kms:${local.region}:${local.account}:alias/${local.stack}-*"
      },
      # RDS, OpenSearch and the RDS-managed master secret encrypt with the environment key through their service.
      {
        Sid      = "EnvironmentKeyThroughServices"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant", "kms:DescribeKey", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"]
        Resource = var.stack.kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = [for s in concat(["rds", "es", "secretsmanager"], var.lambda_pipeline ? ["sqs", "lambda"] : []) : "${s}.${local.region}.amazonaws.com"] }
        }
      },
    ]
  }

  apply_data_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StackBuckets"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucket*", "s3:DeleteBucketPolicy", "s3:DeleteBucketOwnershipControls",
          "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
        ]
        Resource = "${local.arn}:s3:::${local.stack}-*"
      },
      {
        Sid    = "StackDatabase"
        Effect = "Allow"
        Action = ["rds:Create*", "rds:Delete*", "rds:Modify*", "rds:AddTagsToResource", "rds:RemoveTagsFromResource", "rds:RebootDBInstance"]
        Resource = [for t in ["db", "pg", "subgrp", "cluster", "cluster-pg", "snapshot", "cluster-snapshot"] :
        "${local.arn}:rds:${local.region}:${local.account}:${t}:${local.stack}-*"]
      },
      { Sid = "DefaultOptionGroup", Effect = "Allow", Action = "rds:CreateDBInstance", Resource = "${local.arn}:rds:${local.region}:${local.account}:og:default:*" },
      # manage_master_user_password: RDS creates rds!db-* in the caller's name.
      {
        Sid      = "RdsManagedSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:CreateSecret", "secretsmanager:TagResource", "secretsmanager:RotateSecret", "secretsmanager:DeleteSecret"]
        Resource = "${local.arn}:secretsmanager:${local.region}:${local.account}:secret:rds!*"
      },
      {
        Sid      = "StackSearch"
        Effect   = "Allow"
        Action   = ["es:CreateDomain", "es:DeleteDomain", "es:UpdateDomainConfig", "es:UpgradeDomain", "es:AddTags", "es:RemoveTags"]
        Resource = "${local.arn}:es:${local.region}:${local.account}:domain/${local.stack}-*"
      },
      {
        Sid    = "StackLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:TagResource",
          "logs:UntagResource", "logs:TagLogGroup", "logs:UntagLogGroup", "logs:AssociateKmsKey", "logs:DisassociateKmsKey",
        ]
        Resource = flatten([for g in concat(["/aws/opensearch/${local.stack}-"], var.lambda_pipeline ? ["/aws/lambda/${local.stack}-"] : []) :
        ["${local.arn}:logs:${local.region}:${local.account}:log-group:${g}*"]])
      },
      # OpenSearch log publishing: CloudWatch Logs resource policies have no resource-level permission.
      { Sid = "LogResourcePolicy", Effect = "Allow", Action = ["logs:PutResourcePolicy", "logs:DeleteResourcePolicy"], Resource = "*" },
    ]
  }

  apply_pipeline_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PipelineQueues"
        Effect   = "Allow"
        Action   = ["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes", "sqs:TagQueue", "sqs:UntagQueue"]
        Resource = "${local.arn}:sqs:${local.region}:${local.account}:${local.stack}-*"
      },
      {
        Sid    = "PipelineFunction"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion", "lambda:AddPermission", "lambda:RemovePermission", "lambda:TagResource", "lambda:UntagResource",
          "lambda:PutFunctionEventInvokeConfig", "lambda:UpdateFunctionEventInvokeConfig", "lambda:DeleteFunctionEventInvokeConfig",
        ]
        Resource = "${local.arn}:lambda:${local.region}:${local.account}:function:${local.stack}-*"
      },
      {
        Sid       = "PipelineEventSource"
        Effect    = "Allow"
        Action    = ["lambda:CreateEventSourceMapping", "lambda:UpdateEventSourceMapping", "lambda:DeleteEventSourceMapping"]
        Resource  = "*"
        Condition = { ArnLike = { "lambda:FunctionArn" = "${local.arn}:lambda:${local.region}:${local.account}:function:${local.stack}-*" } }
      },
      {
        Sid      = "PipelineRules"
        Effect   = "Allow"
        Action   = ["events:PutRule", "events:DeleteRule", "events:PutTargets", "events:RemoveTargets", "events:TagResource", "events:UntagResource"]
        Resource = "${local.arn}:events:${local.region}:${local.account}:rule/${local.stack}-*"
      },
      {
        Sid      = "PipelineAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
        Resource = "${local.arn}:cloudwatch:${local.region}:${local.account}:alarm:${local.stack}-*"
      },
      {
        Sid      = "PipelineSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:UpdateSecret", "secretsmanager:TagResource", "secretsmanager:UntagResource", "secretsmanager:PutResourcePolicy"]
        Resource = "${local.arn}:secretsmanager:${local.region}:${local.account}:secret:${local.stack}/*"
      },
    ]
  }

  policies = merge(
    {
      read           = { roles = ["plan", "apply"], document = local.read_policy }
      plan           = { roles = ["plan"], document = local.plan_policy }
      apply-state    = { roles = ["apply"], document = local.apply_state_policy }
      apply-identity = { roles = ["apply"], document = local.apply_identity_policy }
      apply-data     = { roles = ["apply"], document = local.apply_data_policy }
    },
    var.lambda_pipeline ? { apply-pipeline = { roles = ["apply"], document = local.apply_pipeline_policy } } : {},
  )
  attachments = merge([for p, v in local.policies : { for r in v.roles : "${r}/${p}" => { role = r, policy = p } }]...)
}

resource "aws_iam_policy" "this" {
  #checkov:skip=CKV_AWS_290:Refresh reads (Describe/List) and KMS CreateKey/logs resource policies have no resource-level permissions; writes are scoped to <stack>-* or by condition.
  #checkov:skip=CKV_AWS_355:Same: read-only Describe/List actions need "*".
  #checkov:skip=CKV_AWS_289:Same: the "*" write actions (KMS CreateKey on a tag/key-spec condition, logs resource policy, Lambda event source mappings on a function condition) cannot be scoped by ARN.
  for_each    = local.policies
  name        = "${var.name}-${each.key}"
  description = "${var.name}: ${each.key} (Terraform CI for ${local.stack})."
  policy      = jsonencode(each.value.document)
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each   = local.attachments
  role       = aws_iam_role.github[each.value.role].name
  policy_arn = aws_iam_policy.this[each.value.policy].arn
}
