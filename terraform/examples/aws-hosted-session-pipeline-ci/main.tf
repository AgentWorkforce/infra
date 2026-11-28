# Bootstrap for .github/workflows/hosted-session-pipeline.yml: GitHub OIDC trust, the hosted root's state bucket
# and key, its private tfvars parameter, and two roles scoped to exactly what that root manages.
#
#   plan  : read the pipeline resources, read state, take the lock, write the plan store once. Never writes state,
#           never reads a secret value.
#   apply : the plan role's reads, plus changes to those same named resources, and state writes.

data "aws_partition" "current" {}

locals {
  p          = data.aws_partition.current.partition
  acct       = var.account_id
  region     = var.region
  prefix     = var.pipeline.name_prefix
  oidc_host  = "token.actions.githubusercontent.com"
  oidc_arn   = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.p}:iam::${local.acct}:oidc-provider/${local.oidc_host}"
  bucket_arn = "arn:${local.p}:s3:::${aws_s3_bucket.state.bucket}"
  plan_store = "${local.bucket_arn}/plans/${trimsuffix(var.state_key, ".tfstate")}"
  param_name = "/${var.name}/tfvars"
  param_arn  = "arn:${local.p}:ssm:${local.region}:${local.acct}:parameter${local.param_name}"

  queues       = ["arn:${local.p}:sqs:${local.region}:${local.acct}:${local.prefix}-session-events", "arn:${local.p}:sqs:${local.region}:${local.acct}:${local.prefix}-session-events-dlq"]
  function_arn = "arn:${local.p}:lambda:${local.region}:${local.acct}:function:${var.pipeline.function_name}"
  rules        = "arn:${local.p}:events:${local.region}:${local.acct}:rule/${local.prefix}-session-*"
  alarms       = "arn:${local.p}:cloudwatch:${local.region}:${local.acct}:alarm:${local.prefix}-session-*"
  role_arn     = "arn:${local.p}:iam::${local.acct}:role/${var.pipeline.role_name}"
  secret_arn   = "arn:${local.p}:secretsmanager:${local.region}:${local.acct}:secret:${var.pipeline.secret_name}-*"
  transcripts  = "arn:${local.p}:s3:::${var.pipeline.bucket_name}"
  log_groups   = [for g in concat(["/aws/lambda/${var.pipeline.function_name}"], var.pipeline.log_group_names) : "arn:${local.p}:logs:${local.region}:${local.acct}:log-group:${g}:*"]
}

# --- OIDC ---

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

data "aws_iam_policy_document" "trust" {
  for_each = { plan = var.plan_environment, apply = var.apply_environment }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # A job bound to a GitHub environment presents repo:<owner/repo>:environment:<name>; only that job can assume.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:environment:${each.value}"]
    }
  }
}

# --- State bucket, key and tfvars parameter ---

resource "aws_kms_key" "state" {
  description         = "${var.name}: hosted session-pipeline state, saved plans and tfvars"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = "${var.name}-${local.acct}-${local.region}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# The value is the hosted root's private tfvars JSON. Its owner writes it (aws ssm put-parameter ... --overwrite);
# every write is a new version, and a plan records the version it read. Terraform never manages the value.
resource "aws_ssm_parameter" "tfvars" {
  name   = local.param_name
  type   = "SecureString"
  key_id = aws_kms_key.state.arn
  value  = "{}"
  tags   = var.tags
  lifecycle { ignore_changes = [value] }
}

# --- Permissions ---

locals {
  common_reads = [
    { Sid = "TfvarsRead", Effect = "Allow", Action = "ssm:GetParameter", Resource = local.param_arn },
    { Sid = "CiKey", Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = aws_kms_key.state.arn },
    { Sid = "StateList", Effect = "Allow", Action = "s3:ListBucket", Resource = local.bucket_arn },
    { Sid = "StateRead", Effect = "Allow", Action = "s3:GetObject", Resource = ["${local.bucket_arn}/${var.state_key}", "${local.plan_store}/*"] },
    { Sid = "StateLock", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${local.bucket_arn}/${var.state_key}.tflock" },
    { Sid = "PlanStoreWriteOnce", Effect = "Allow", Action = "s3:PutObject", Resource = "${local.plan_store}/*", Condition = { StringEquals = { "s3:if-none-match" = "*" } } },
    { Sid = "Identity", Effect = "Allow", Action = ["sts:GetCallerIdentity"], Resource = "*" },
    { Sid = "ReadQueues", Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueueTags", "sqs:ListDeadLetterSourceQueues"], Resource = local.queues },
    { Sid = "ReadFunction", Effect = "Allow", Action = ["lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetPolicy", "lambda:ListTags", "lambda:GetFunctionCodeSigningConfig"], Resource = local.function_arn },
    { Sid = "ReadMappings", Effect = "Allow", Action = ["lambda:GetEventSourceMapping", "lambda:ListEventSourceMappings", "lambda:ListTags"], Resource = "*" },
    { Sid = "ReadRules", Effect = "Allow", Action = ["events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource"], Resource = local.rules },
    { Sid = "ReadAlarms", Effect = "Allow", Action = ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"], Resource = "*" },
    { Sid = "ReadLogs", Effect = "Allow", Action = ["logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:ListTagsLogGroup"], Resource = "*" },
    { Sid = "ReadSecretMetadata", Effect = "Allow", Action = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"], Resource = local.secret_arn },
    { Sid = "ReadRole", Effect = "Allow", Action = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags"], Resource = local.role_arn },
    { Sid = "ReadTranscriptsBucket", Effect = "Allow", Action = ["s3:GetBucketPolicy", "s3:GetBucketNotification"], Resource = local.transcripts },
    { Sid = "ReadTranscriptsKey", Effect = "Allow", Action = ["kms:GetKeyPolicy", "kms:DescribeKey"], Resource = var.pipeline.kms_key_arn },
    { Sid = "NoSecretValues", Effect = "Deny", Action = "secretsmanager:GetSecretValue", Resource = "*" },
  ]

  plan_only = [
    { Sid = "NeverWriteState", Effect = "Deny", Action = ["s3:PutObject", "s3:DeleteObject"], Resource = "${local.bucket_arn}/${var.state_key}" },
  ]

  write_state = { Sid = "WriteState", Effect = "Allow", Action = "s3:PutObject", Resource = "${local.bucket_arn}/${var.state_key}" }
  write_mapping = {
    Sid       = "WriteMapping"
    Effect    = "Allow"
    Action    = ["lambda:UpdateEventSourceMapping", "lambda:TagResource", "lambda:UntagResource"]
    Resource  = "arn:${local.p}:lambda:${local.region}:${local.acct}:event-source-mapping:*"
    Condition = { StringEquals = { "lambda:FunctionArn" = local.function_arn } }
  }
  no_deletes = { Sid = "NoDeletes", Effect = "Deny", Action = ["sqs:DeleteQueue", "lambda:DeleteEventSourceMapping", "lambda:DeleteFunction", "events:DeleteRule", "cloudwatch:DeleteAlarms", "secretsmanager:DeleteSecret", "iam:DeleteRole", "iam:DeleteRolePolicy", "s3:DeleteBucketPolicy", "kms:ScheduleKeyDeletion", "kms:DisableKey"], Resource = "*" }

  # Adoption: an import writes only state, and the one approved change is the mapping's concurrency.
  adoption_writes = [local.write_state, local.write_mapping, local.no_deletes]

  full_writes = [
    local.write_state,
    local.write_mapping,
    { Sid = "WriteQueues", Effect = "Allow", Action = ["sqs:SetQueueAttributes", "sqs:TagQueue", "sqs:UntagQueue"], Resource = local.queues },
    { Sid = "WriteFunctionPolicy", Effect = "Allow", Action = ["lambda:AddPermission", "lambda:RemovePermission"], Resource = local.function_arn },
    { Sid = "WriteRules", Effect = "Allow", Action = ["events:PutRule", "events:PutTargets", "events:RemoveTargets", "events:EnableRule", "events:DisableRule", "events:TagResource", "events:UntagResource"], Resource = local.rules },
    { Sid = "WriteAlarms", Effect = "Allow", Action = ["cloudwatch:PutMetricAlarm", "cloudwatch:TagResource", "cloudwatch:UntagResource"], Resource = local.alarms },
    { Sid = "WriteLogs", Effect = "Allow", Action = ["logs:PutRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup"], Resource = local.log_groups },
    { Sid = "WriteSecretMetadata", Effect = "Allow", Action = ["secretsmanager:UpdateSecret", "secretsmanager:PutResourcePolicy", "secretsmanager:TagResource", "secretsmanager:UntagResource"], Resource = local.secret_arn },
    { Sid = "WriteRole", Effect = "Allow", Action = ["iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:TagRole", "iam:UntagRole"], Resource = local.role_arn },
    { Sid = "WriteTranscriptsBucket", Effect = "Allow", Action = ["s3:PutBucketPolicy", "s3:PutBucketNotification"], Resource = local.transcripts },
    { Sid = "WriteTranscriptsKey", Effect = "Allow", Action = ["kms:PutKeyPolicy"], Resource = var.pipeline.kms_key_arn },
    local.no_deletes,
  ]
}

resource "aws_iam_role" "ci" {
  for_each             = { plan = "plan", apply = "apply" }
  name                 = "${var.name}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy" "ci" {
  for_each = aws_iam_role.ci
  name     = "hosted-session-pipeline"
  role     = each.value.name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.common_reads, jsondecode(each.key == "plan" ? jsonencode(local.plan_only) : (var.apply_scope == "full" ? jsonencode(local.full_writes) : jsonencode(local.adoption_writes))))
  })
}
