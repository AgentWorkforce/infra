data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  function_name      = "${var.name}-session-pipeline"
  queue_name         = "${var.name}-session-events"
  dlq_name           = "${var.name}-session-events-dlq"
  function_arn       = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.function_name}"
  bucket_arn         = "arn:${local.partition}:s3:::${var.bucket_name}"
  key_prefix         = trim(var.key_prefix, "/")
  secret_arn         = var.create_secret ? aws_secretsmanager_secret.pipeline[0].arn : var.secret_arn
  in_vpc             = length(var.vpc_subnet_ids) > 0
  is_image           = var.package.image_uri != null
  execution_role_arn = var.existing_execution_role_arn != null ? var.existing_execution_role_arn : aws_iam_role.this[0].arn

  environment = merge({
    PIPELINE_RAW_S3_BUCKET              = var.bucket_name
    PIPELINE_KEY_PREFIX                 = local.key_prefix
    PIPELINE_ORG_FROM_PREFIX            = "true"
    SESSION_PIPELINE_SECRET_ARN         = local.secret_arn
    SESSION_PIPELINE_QUEUE_URL          = aws_sqs_queue.events.url
    SEARCH_INDEX_ENABLED                = var.search_index_enabled ? "1" : "0"
    PIPELINE_FANOUT                     = "off"
    PIPELINE_RECONCILE_LOOKBACK_MINUTES = tostring(2 * var.reconcile_minutes)
    HOOPDB_POOL_MAX                     = "4"
    OTEL_SERVICE_NAME                   = "96bulls-session-pipeline"
    NODE_OPTIONS                        = "--enable-source-maps"
    SESSION_BRIEF_ENABLED               = var.briefs_enabled ? "true" : "false"
  }, var.environment)
}

# ---------------------------------------------------------------------------
# Queues
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                              = local.dlq_name
  message_retention_seconds         = var.dlq_retention_seconds
  sqs_managed_sse_enabled           = var.queue_kms_key_arn == null ? true : null
  kms_master_key_id                 = var.queue_kms_key_arn
  kms_data_key_reuse_period_seconds = var.queue_kms_key_arn == null ? null : 300
  tags                              = var.tags
}

resource "aws_sqs_queue" "events" {
  name          = local.queue_name
  delay_seconds = var.delivery_delay_seconds
  # Six times the timeout (AWS guidance for SQS sources) plus the batching
  # window, so no message reappears while its invocation still runs.
  visibility_timeout_seconds        = 6 * var.timeout_seconds + var.maximum_batching_window_seconds
  message_retention_seconds         = var.queue_retention_seconds
  receive_wait_time_seconds         = 20
  sqs_managed_sse_enabled           = var.queue_kms_key_arn == null ? true : null
  kms_master_key_id                 = var.queue_kms_key_arn
  kms_data_key_reuse_period_seconds = var.queue_kms_key_arn == null ? null : 300
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "sqs:*"
      Resource  = aws_sqs_queue.dlq.arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.events.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "BucketManifestEvents"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.events.arn
        Condition = {
          ArnEquals    = { "aws:SourceArn" = local.bucket_arn }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
    ]
  })
}

resource "aws_s3_bucket_notification" "manifests" {
  count = var.manage_bucket_notification ? 1 : 0

  bucket = var.bucket_name

  queue {
    id            = "${var.name}-session-pipeline-manifests"
    queue_arn     = aws_sqs_queue.events.arn
    events        = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix = "${local.key_prefix}/"
    filter_suffix = "/manifest.json"
  }

  depends_on = [aws_sqs_queue_policy.events]
}

# ---------------------------------------------------------------------------
# Secret (a container; the value is set out of band and never in state)
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "pipeline" {
  #checkov:skip=CKV2_AWS_57:A container whose value (HoopDb URL, search credentials) is set and rotated by its owner out of band.
  count = var.create_secret ? 1 : 0

  name                    = "${var.name}/session-pipeline"
  description             = "agent-relay session pipeline: HoopDb URL and search backend credentials (JSON)"
  kms_key_id              = var.secret_kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

# Migrate managed-role state without replacing existing roles when introducing count.
moved {
  from = aws_iam_role.this
  to   = aws_iam_role.this[0]
}

moved {
  from = aws_iam_role_policy.this
  to   = aws_iam_role_policy.this[0]
}

resource "aws_iam_role" "this" {
  count                = var.existing_execution_role_arn == null ? 1 : 0
  name                 = local.function_name
  path                 = var.role_path
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

locals {
  role_statements = concat(
    [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.this.arn}:*"]
      },
      {
        # Unconditional ListBucket: S3 answers 404 (not 403) for a missing
        # manifest only with it, and the pipeline detects deletes that way.
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "ReadSessionObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.bucket_arn}/${local.key_prefix}/*/${var.layout_version}/*"]
      },
      {
        # Consume, and re-enqueue from the reconcile.
        Sid      = "SessionEvents"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:SendMessage"]
        Resource = [aws_sqs_queue.events.arn]
      },
      {
        Sid      = "PipelineSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.secret_arn]
      },
      {
        # A reconcile at its deadline hands its cursor to the next link by
        # invoking itself asynchronously.
        Sid      = "ReconcileContinues"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [local.function_arn]
      },
    ],
    var.bucket_kms_key_arn == null ? [] : [{
      Sid      = "DecryptSessionObjectsViaS3"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = [var.bucket_kms_key_arn]
      Condition = {
        StringEquals = { "kms:ViaService" = "s3.${local.region}.${local.dns_suffix}" }
        # With S3 Bucket Keys (aws/object-storage enables them) the encryption
        # context is the bucket ARN; without them it is the object ARN. Object
        # access stays limited by the s3:GetObject statement.
        StringLike = { "kms:EncryptionContext:aws:s3:arn" = [local.bucket_arn, "${local.bucket_arn}/${local.key_prefix}/*"] }
      }
    }],
    var.queue_kms_key_arn == null ? [] : [{
      Sid      = "QueueKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = [var.queue_kms_key_arn]
    }],
    var.secret_kms_key_arn == null ? [] : [{
      Sid       = "SecretKey"
      Effect    = "Allow"
      Action    = ["kms:Decrypt"]
      Resource  = [var.secret_kms_key_arn]
      Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.${local.dns_suffix}" } }
    }],
    # ENI management for VPC functions; these EC2 actions do not support
    # resource-level permissions.
    local.in_vpc ? [{
      Sid      = "VpcNetworkInterfaces"
      Effect   = "Allow"
      Action   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses", "ec2:DescribeSubnets", "ec2:DescribeVpcs"]
      Resource = ["*"]
    }] : [],
    var.additional_policy_statements,
  )
}

resource "aws_iam_role_policy" "this" {
  count  = var.existing_execution_role_arn == null ? 1 : 0
  name   = "session-pipeline"
  role   = aws_iam_role.this[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.role_statements })
}

# ---------------------------------------------------------------------------
# Function
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_338:Retention is the customer's choice (log_retention_days, default 30).
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_116:SQS-sourced: failed messages go to the session-events DLQ through the queue redrive policy.
  #checkov:skip=CKV_AWS_272:Code signing is opt-in (code_signing_config_arn); container images must be pinned by digest (validated).
  #checkov:skip=CKV_AWS_117:VPC placement is opt-in (vpc_subnet_ids); needed only to reach a private HoopDb.
  function_name = local.function_name
  role          = local.execution_role_arn
  description   = "agent-relay session pipeline (event-driven mode): manifest events to HoopDb pointers and search index"

  package_type      = local.is_image ? "Image" : "Zip"
  image_uri         = var.package.image_uri
  s3_bucket         = var.package.s3_bucket
  s3_key            = var.package.s3_key
  s3_object_version = var.package.s3_object_version
  filename          = var.package.filename
  source_code_hash  = var.package.source_code_hash
  handler           = local.is_image ? null : var.handler
  runtime           = local.is_image ? null : var.runtime
  architectures     = [var.architecture]

  memory_size                    = var.memory_size
  timeout                        = var.timeout_seconds
  reserved_concurrent_executions = var.reserved_concurrent_executions
  kms_key_arn                    = var.lambda_kms_key_arn
  code_signing_config_arn        = var.code_signing_config_arn

  environment {
    variables = local.environment
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  tracing_config {
    mode = var.tracing_mode
  }

  dynamic "vpc_config" {
    for_each = local.in_vpc ? [1] : []
    content {
      subnet_ids         = var.vpc_subnet_ids
      security_group_ids = var.vpc_security_group_ids
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.existing_execution_role_arn == null ? true : startswith(var.existing_execution_role_arn, "arn:${local.partition}:iam::${local.account_id}:role/")
      error_message = "The existing execution role must belong to the caller's account and partition."
    }
    precondition {
      condition     = !local.in_vpc || length(var.vpc_security_group_ids) > 0
      error_message = "vpc_subnet_ids needs vpc_security_group_ids."
    }
    precondition {
      condition     = var.create_secret || var.secret_arn != null
      error_message = "Set secret_arn when create_secret is false."
    }
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "aws_lambda_function_event_invoke_config" "this" {
  function_name                = aws_lambda_function.this.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
}

resource "aws_lambda_event_source_mapping" "events" {
  function_name                      = aws_lambda_function.this.arn
  event_source_arn                   = aws_sqs_queue.events.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = var.maximum_batching_window_seconds
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = var.enabled

  scaling_config {
    maximum_concurrency = var.max_concurrency
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "reconcile" {
  name                = "${var.name}-session-reconcile"
  description         = "agent-relay session pipeline: reconcile recent manifests (lost notifications)"
  schedule_expression = "rate(${var.reconcile_minutes} minutes)"
  state               = var.enabled ? "ENABLED" : "DISABLED"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "reconcile" {
  rule      = aws_cloudwatch_event_rule.reconcile.name
  target_id = "session-pipeline"
  arn       = aws_lambda_function.this.arn
  input     = jsonencode({ reconcile = true })
}

resource "aws_lambda_permission" "reconcile" {
  statement_id   = "session-reconcile"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.reconcile.arn
  source_account = local.account_id
}

# Present but DISABLED unless briefs_enabled, so nothing is invoked while
# briefs are off (the function also returns early without SESSION_BRIEF_ENABLED).
resource "aws_cloudwatch_event_rule" "brief" {
  name                = "${var.name}-session-brief"
  description         = "agent-relay session pipeline: one session-brief tick (due wakeups)"
  schedule_expression = var.brief_schedule_expression
  state               = var.enabled && var.briefs_enabled ? "ENABLED" : "DISABLED"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "brief" {
  rule      = aws_cloudwatch_event_rule.brief.name
  target_id = "session-pipeline"
  arn       = aws_lambda_function.this.arn
  input     = jsonencode({ brief = true })
}

resource "aws_lambda_permission" "brief" {
  statement_id   = "session-brief"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.brief.arn
  source_account = local.account_id
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.dlq_name}-not-empty"
  alarm_description   = "Session pipeline messages exhausted their retries; inspect and redrive the DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_actions) > 0
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backlog_age" {
  alarm_name          = "${local.queue_name}-backlog-age"
  alarm_description   = "Oldest session event is older than 15 minutes: the pipeline is behind or failing."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.events.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_actions) > 0
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.function_name}-errors"
  alarm_description   = "Session pipeline invocations are failing (init, timeouts, crashes)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.this.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = length(var.alarm_actions) > 0
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = var.tags
}
