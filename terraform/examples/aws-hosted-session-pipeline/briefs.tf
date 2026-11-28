# Push-based session summaries (T130, code only; production enablement is held). PROVISIONAL names until
# relayhistory-pipeline confirms the contract. Off by default: with briefs_queue.create = false nothing here is
# planned, so the adoption plan is unchanged.
#
#   producer : the session-pipeline function, right after it commits a manifest append or session end (and the
#              recovery sweep), sends {kind, org, workspace, session, revision, digest, first_uncovered_at}.
#   consumer : the same function through its own event source mapping, created DISABLED.
#   grants   : resource policy on the queue naming the pipeline role (the role is imported as-is; no IAM change).

variable "briefs_queue" {
  description = "Push-summary queue. create plans the queue, DLQ, policy, alarm and a DISABLED mapping; esm_enabled turns consumption on (production enablement, held)."
  type = object({
    create            = optional(bool, false)
    esm_enabled       = optional(bool, false)
    max_concurrency   = optional(number, 2)
    batch_size        = optional(number, 10)
    max_receive_count = optional(number, 8)
  })
  default = {}
  validation {
    condition     = var.briefs_queue.max_concurrency >= 2 && var.briefs_queue.max_concurrency <= 1000 && var.briefs_queue.batch_size >= 1 && var.briefs_queue.batch_size <= 10
    error_message = "briefs_queue: max_concurrency 2-1000, batch_size 1-10."
  }
  validation {
    condition     = !var.briefs_queue.esm_enabled || var.briefs_queue.create
    error_message = "briefs_queue.esm_enabled needs create."
  }
}

locals {
  briefs     = var.briefs_queue.create ? toset(["briefs"]) : toset([])
  briefs_q   = "${var.name_prefix}-session-briefs"
  briefs_dlq = "${var.name_prefix}-session-briefs-dlq"
  # Every event source mapping on the pipeline function targets this one value (unqualified today, as live), so
  # session-events, briefs and any later queue always run the same code; an alias flip moves all of them at once.
  pipeline_esm_target = module.pipeline.function_arn
}

resource "aws_sqs_queue" "briefs_dlq" {
  for_each                  = local.briefs
  name                      = local.briefs_dlq
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "briefs" {
  for_each = local.briefs
  name     = local.briefs_q
  # No delay: the pipeline coalesces, bounded from the oldest uncovered append.
  delay_seconds              = 0
  visibility_timeout_seconds = 6 * var.function_timeout_seconds
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.briefs_dlq["briefs"].arn, maxReceiveCount = var.briefs_queue.max_receive_count })
  tags                       = var.tags
}

resource "aws_sqs_queue_policy" "briefs" {
  for_each  = local.briefs
  queue_url = aws_sqs_queue.briefs["briefs"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.briefs["briefs"].arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } },
      { Sid = "SessionPipelineProducesAndConsumes", Effect = "Allow", Principal = { AWS = local.role_arn }, Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.briefs["briefs"].arn },
    ]
  })
}

resource "aws_sqs_queue_policy" "briefs_dlq" {
  for_each  = local.briefs
  queue_url = aws_sqs_queue.briefs_dlq["briefs"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.briefs_dlq["briefs"].arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }]
  })
}

resource "aws_lambda_event_source_mapping" "briefs" {
  for_each                           = local.briefs
  function_name                      = local.pipeline_esm_target
  event_source_arn                   = aws_sqs_queue.briefs["briefs"].arn
  batch_size                         = var.briefs_queue.batch_size
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = var.briefs_queue.esm_enabled
  scaling_config {
    maximum_concurrency = var.briefs_queue.max_concurrency
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "briefs_dlq" {
  #checkov:skip=CKV_AWS_319:Matches the pipeline's other alarms (actions disabled until alarm routing is a reviewed change).
  for_each            = local.briefs
  alarm_name          = "${local.briefs_dlq}-not-empty"
  alarm_description   = "Push-summary jobs exhausted their retries."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = local.briefs_dlq }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = false
  tags                = var.tags
}

output "briefs_queue_url" {
  description = "Push-summary queue URL (SESSION_BRIEF_QUEUE_URL, provisional), or null."
  value       = var.briefs_queue.create ? aws_sqs_queue.briefs["briefs"].id : null
}
