# Hosted session pipeline: the AWS wiring around the session-pipeline Lambda, moved from the
# relayhistory-pipeline Alchemy stack (stacks/aws/session-pipeline.ts) into Terraform.
#
# Resources mirror that stack attribute for attribute (names, descriptions, Sids), so an import
# plans zero changes. Phase 1 adopts the function (its code and environment stay with the pipeline
# deploy); phase 2 manages it here once the pipeline publishes a pinned artifact.

data "aws_partition" "current" {}

data "aws_lambda_function" "pipeline" {
  function_name = var.function_name
}

locals {
  partition  = data.aws_partition.current.partition
  region     = var.region
  account_id = var.account_id

  queue_name = "${var.name_prefix}-session-events"
  dlq_name   = "${var.name_prefix}-session-events-dlq"
  queue_arn  = "arn:${local.partition}:sqs:${local.region}:${local.account_id}:${local.queue_name}"
  dlq_arn    = "arn:${local.partition}:sqs:${local.region}:${local.account_id}:${local.dlq_name}"
  bucket_arn = "arn:${local.partition}:s3:::${var.bucket_name}"

  function_arn = data.aws_lambda_function.pipeline.arn
  role_arn     = aws_iam_role.pipeline.arn
  key_prefix   = trim(var.key_prefix, "/")

  # The old stack's optional schedule groups: rule name suffix, description, rate and tick body.
  schedule_catalog = {
    analysisCache = [
      { key = "analysis_cache", name = "${var.name_prefix}-session-reconcile-analysis-cache", description = "96bulls bounded demand analysis-cache refresh", rate = "rate(1 minute)", input = jsonencode({ analysisCache = true }) },
      { key = "analysis_reconcile", name = "${var.name_prefix}-session-reconcile-analysis-backfill", description = "96bulls bounded analysis-cache source discovery", rate = "rate(30 minutes)", input = jsonencode({ analysisCacheReconcile = true }) },
    ]
    semanticCopy          = [{ key = "semantic_copy", name = "${var.name_prefix}-session-semantic-copy", description = "96bulls verified global feature copy", rate = "rate(1 minute)", input = jsonencode({ semanticCopy = true }) }]
    analysisJob           = [{ key = "analysis_job", name = "${var.name_prefix}-session-analysis-jobs", description = "96bulls session analysis jobs (relayhistory engine port)", rate = "rate(1 minute)", input = jsonencode({ sessionAnalysis = true }) }]
    bufferedSearchFeed    = [{ key = "buffered_search_feed", name = "${var.name_prefix}-session-buffered-search-feed", description = "96bulls bounded buffered-stage search feed", rate = "rate(1 minute)", input = jsonencode({ bufferedSearchFeed = true }) }]
    bufferedErasureDelete = [{ key = "buffered_erasure_delete", name = "${var.name_prefix}-session-buffered-erasure-delete", description = "96bulls bounded buffered-row later-erasure delete", rate = "rate(1 minute)", input = jsonencode({ bufferedErasureDelete = true }) }]
  }

  schedules = merge(
    {
      reconcile = { name = "${var.name_prefix}-session-reconcile", description = "96bulls session pipeline: reconcile recent manifests (lost notifications)", rate = "rate(${var.reconcile_minutes} minutes)", input = jsonencode({ reconcile = true }), enabled = true }
      brief     = { name = "${var.name_prefix}-session-brief", description = "96bulls session pipeline: one session-brief tick (due wakeups)", rate = "rate(1 minute)", input = jsonencode({ brief = true }), enabled = var.briefs_enabled }
    },
    merge([for group, on in var.optional_schedules : {
      for s in local.schedule_catalog[group] : s.key => merge(s, { enabled = on })
    }]...)
  )

  # Every resource-policy grant on the function: one per schedule, plus the reconcile chain's self-invoke.
  permissions = merge(
    { for k, s in local.schedules : k => { principal = "events.amazonaws.com", source_arn = aws_cloudwatch_event_rule.schedule[k].arn, source_account = local.account_id } },
    { reconcile_continue = { principal = local.role_arn, source_arn = null, source_account = null } }
  )
}

# --- Queues ---

resource "aws_sqs_queue" "dlq" {
  name                      = local.dlq_name
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
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
      Resource  = local.dlq_arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_sqs_queue" "events" {
  name                       = local.queue_name
  delay_seconds              = 30
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 8
  })
  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.visibility_timeout_seconds >= var.function_timeout_seconds
      error_message = "visibility_timeout_seconds must be at least the function timeout."
    }
  }
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
        Resource  = local.queue_arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "TranscriptBucketEvents"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = local.queue_arn
        Condition = { ArnEquals = { "aws:SourceArn" = local.bucket_arn }, StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "SessionPipelineConsumes"
        Effect    = "Allow"
        Principal = { AWS = local.role_arn }
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:SendMessage"]
        Resource  = local.queue_arn
      },
    ]
  })
}

resource "aws_lambda_event_source_mapping" "events" {
  function_name                      = local.function_arn
  event_source_arn                   = aws_sqs_queue.events.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 20
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
  scaling_config {
    maximum_concurrency = var.max_concurrency
  }
  tags = var.tags
}

# --- Schedules and invoke permissions ---

resource "aws_cloudwatch_event_rule" "schedule" {
  for_each            = local.schedules
  name                = each.value.name
  description         = each.value.description
  schedule_expression = each.value.rate
  state               = each.value.enabled ? "ENABLED" : "DISABLED"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "schedule" {
  for_each  = local.schedules
  rule      = aws_cloudwatch_event_rule.schedule[each.key].name
  target_id = "session-pipeline"
  arn       = local.function_arn
  input     = each.value.input
}

resource "aws_lambda_permission" "pipeline" {
  for_each       = local.permissions
  statement_id   = lookup(var.import_ids.permission_statement_ids, each.key, null)
  action         = "lambda:InvokeFunction"
  function_name  = var.function_name
  principal      = each.value.principal
  source_arn     = each.value.source_arn
  source_account = each.value.source_account

  lifecycle {
    precondition {
      condition     = contains(keys(var.import_ids.permission_statement_ids), each.key)
      error_message = "import_ids.permission_statement_ids needs the live statement id for every permission."
    }
  }
}

# --- Alarms (actions disabled, as live) ---

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.dlq_name}-not-empty"
  alarm_description   = "Session pipeline messages exhausted their retries (runbooks/sessions-prod-session-pipeline.md, DLQ)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = local.dlq_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = false
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backlog_age" {
  alarm_name          = "${local.queue_name}-backlog-age"
  alarm_description   = "Oldest session event is older than 15 minutes: the pipeline is behind or failing."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = local.queue_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = false
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.function_name}-errors"
  alarm_description   = "Session pipeline invocations are failing (init, timeouts, crashes)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = false
  tags                = var.tags
}

# --- Secret container (value set out of band, never read here) ---

resource "aws_secretsmanager_secret" "pipeline" {
  name        = var.secret_name
  description = var.secret_description
  tags        = var.tags
}

resource "aws_secretsmanager_secret_policy" "pipeline" {
  secret_arn = aws_secretsmanager_secret.pipeline.arn
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "SessionPipelineReads", Effect = "Allow", Principal = { AWS = local.role_arn }, Action = "secretsmanager:GetSecretValue", Resource = "*" }]
  })
}

# --- Execution role (imported as-is) ---

resource "aws_iam_role" "pipeline" {
  name                 = var.role.name
  path                 = var.role.path
  description          = var.role.description
  assume_role_policy   = var.role.assume_role_policy
  max_session_duration = var.role.max_session_duration
  permissions_boundary = var.role.permissions_boundary
  tags                 = var.role.tags
}

resource "aws_iam_role_policy" "pipeline" {
  for_each = var.role.inline_policies
  name     = each.key
  role     = aws_iam_role.pipeline.name
  policy   = each.value
}

resource "aws_iam_role_policy_attachment" "pipeline" {
  for_each   = var.role.managed_policy_arns
  role       = aws_iam_role.pipeline.name
  policy_arn = each.value
}

resource "aws_cloudwatch_log_group" "pipeline" {
  count             = var.log_group == null ? 0 : 1
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_group.retention_in_days
  tags              = var.log_group.tags
}

# --- Transcripts bucket: notifications and policy ---

resource "aws_s3_bucket_notification" "transcripts" {
  bucket = var.bucket_name

  queue {
    id            = "96bulls-session-pipeline-manifests"
    queue_arn     = aws_sqs_queue.events.arn
    events        = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix = "${local.key_prefix}/"
    filter_suffix = "/manifest.json"
  }

  dynamic "queue" {
    for_each = var.upload_queue_configuration == null ? [] : [var.upload_queue_configuration]
    content {
      id            = queue.value.id
      queue_arn     = queue.value.queue_arn
      events        = queue.value.events
      filter_prefix = queue.value.filter_prefix
      filter_suffix = queue.value.filter_suffix
    }
  }
}

locals {
  analysis_glob = "${local.key_prefix}/*/${var.layout_version}/*/normalized/session-analysis-v2/*"

  pipeline_bucket_statements = concat(
    # Through JSON, so both branches have one type (the statements differ in shape).
    jsondecode(var.analysis_results ? jsonencode([
      { Sid = "SessionPipelineWritesAnalysisResults", Effect = "Allow", Principal = { AWS = local.role_arn }, Action = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = ["${local.bucket_arn}/${local.analysis_glob}"] },
      { Sid = "SessionPipelineListsAnalysisResultVersions", Effect = "Allow", Principal = { AWS = local.role_arn }, Action = ["s3:ListBucketVersions"], Resource = [local.bucket_arn], Condition = { StringLike = { "s3:prefix" = [local.analysis_glob] } } },
    ]) : "[]"),
    [
      { Sid = "SessionPipelineLists", Effect = "Allow", Principal = { AWS = local.role_arn }, Action = ["s3:ListBucket"], Resource = [local.bucket_arn] },
      { Sid = "SessionPipelineReads", Effect = "Allow", Principal = { AWS = local.role_arn }, Action = ["s3:GetObject"], Resource = ["${local.bucket_arn}/${local.key_prefix}/*/${var.layout_version}/*"] },
    ]
  )

  pipeline_key_statements = concat(
    [{
      Sid       = "SessionPipelineDecryptsViaS3"
      Effect    = "Allow"
      Principal = { AWS = local.role_arn }
      Action    = ["kms:Decrypt"]
      Resource  = "*"
      Condition = {
        StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com", "kms:CallerAccount" = local.account_id }
        StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "arn:${local.partition}:s3:::${var.bucket_name}/${local.key_prefix}/*" }
      }
    }],
    jsondecode(var.analysis_results ? jsonencode([{
      Sid       = "SessionPipelineEncryptsAnalysisResultsViaS3"
      Effect    = "Allow"
      Principal = { AWS = local.role_arn }
      Action    = ["kms:GenerateDataKey", "kms:Encrypt"]
      Resource  = "*"
      Condition = {
        StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com", "kms:CallerAccount" = local.account_id }
        StringLike   = { "kms:EncryptionContext:aws:s3:arn" = "arn:${local.partition}:s3:::${var.bucket_name}/${local.analysis_glob}" }
      }
    }]) : "[]")
  )

  other_bucket_statements = jsondecode(var.bucket_policy_other_statements)
  other_key_statements    = jsondecode(var.kms_policy_other_statements)
  rendered_bucket_sids    = [for s in local.pipeline_bucket_statements : s.Sid]
  rendered_key_sids       = [for s in local.pipeline_key_statements : s.Sid]
}

resource "aws_s3_bucket_policy" "transcripts" {
  bucket = var.bucket_name
  policy = jsonencode(merge(var.bucket_policy_id == null ? {} : { Id = var.bucket_policy_id }, { Version = "2012-10-17", Statement = concat(local.pipeline_bucket_statements, local.other_bucket_statements) }))

  lifecycle {
    precondition {
      condition     = length([for s in local.other_bucket_statements : s if contains(local.rendered_bucket_sids, try(s.Sid, ""))]) == 0
      error_message = "bucket_policy_other_statements repeats a statement this root renders; drop it from the private list."
    }
  }
}

resource "aws_kms_key_policy" "transcripts" {
  key_id = var.kms_key_id
  policy = jsonencode(merge(var.kms_policy_id == null ? {} : { Id = var.kms_policy_id }, { Version = "2012-10-17", Statement = concat(local.pipeline_key_statements, local.other_key_statements) }))

  lifecycle {
    precondition {
      condition     = length([for s in local.other_key_statements : s if contains(local.rendered_key_sids, try(s.Sid, ""))]) == 0
      error_message = "kms_policy_other_statements repeats a statement this root renders; drop it from the private list."
    }
  }
}
