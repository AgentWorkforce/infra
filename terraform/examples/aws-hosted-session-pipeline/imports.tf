# First-plan imports. Every id is a live identifier from the private tfvars, or is derived from a
# name that is. Once a resource is in state its import block is a no-op.
#
# Apply rule (Khaliq, 2026-11-27): import and apply only through infra CI, and only when the
# reviewed plan after import shows zero changes. Any non-zero diff: no apply.

import {
  for_each = local.import_one
  to       = module.pipeline.aws_sqs_queue.dlq
  id       = "https://sqs.${var.region}.amazonaws.com/${var.account_id}/${local.dlq_name}"
}

import {
  for_each = local.import_one
  to       = aws_sqs_queue_policy.dlq
  id       = "https://sqs.${var.region}.amazonaws.com/${var.account_id}/${local.dlq_name}"
}

import {
  for_each = local.import_one
  to       = module.pipeline.aws_sqs_queue.events
  id       = "https://sqs.${var.region}.amazonaws.com/${var.account_id}/${local.queue_name}"
}

import {
  for_each = local.import_one
  to       = aws_sqs_queue_policy.events
  id       = "https://sqs.${var.region}.amazonaws.com/${var.account_id}/${local.queue_name}"
}

import {
  for_each = local.import_one
  to       = module.pipeline.aws_lambda_event_source_mapping.events
  id       = var.import_ids.event_source_mapping_uuid
}

import {
  for_each = local.import_one
  to       = module.pipeline.aws_cloudwatch_event_rule.reconcile
  id       = "${var.name_prefix}-session-reconcile"
}

import {
  for_each = local.import_one
  to       = module.pipeline.aws_cloudwatch_event_rule.brief
  id       = "${var.name_prefix}-session-brief"
}

import {
  for_each = local.import_one
  to       = module.pipeline.aws_cloudwatch_event_target.reconcile
  id       = "${var.name_prefix}-session-reconcile/session-pipeline"
}

import {
  for_each = local.import_one
  to       = module.pipeline.aws_cloudwatch_event_target.brief
  id       = "${var.name_prefix}-session-brief/session-pipeline"
}

import {
  for_each = { for k, v in local.schedules : k => v if var.import_existing }
  to       = aws_cloudwatch_event_rule.schedule[each.key]
  id       = each.value.name
}

import {
  for_each = { for k, v in local.schedules : k => v if var.import_existing }
  to       = aws_cloudwatch_event_target.schedule[each.key]
  id       = "${each.value.name}/session-pipeline"
}

import {
  for_each = { for k, v in local.permissions : k => v if var.import_existing }
  to       = aws_lambda_permission.pipeline[each.key]
  id       = "${var.function_name}/${lookup(var.import_ids.permission_statement_ids, each.key, "missing")}"
}

import {
  for_each = local.import_one
  to       = aws_cloudwatch_metric_alarm.dlq_not_empty
  id       = "${local.dlq_name}-not-empty"
}

import {
  for_each = local.import_one
  to       = aws_cloudwatch_metric_alarm.backlog_age
  id       = "${local.queue_name}-backlog-age"
}

import {
  for_each = local.import_one
  to       = aws_cloudwatch_metric_alarm.errors
  id       = "${var.function_name}-errors"
}

import {
  for_each = local.import_one
  to       = aws_secretsmanager_secret.pipeline
  id       = var.import_ids.secret_arn
}

import {
  for_each = local.import_one
  to       = aws_secretsmanager_secret_policy.pipeline
  id       = var.import_ids.secret_arn
}

import {
  for_each = local.import_one
  to       = aws_iam_role.pipeline
  id       = var.role.name
}

import {
  for_each = { for k, v in var.role.inline_policies : k => v if var.import_existing }
  to       = aws_iam_role_policy.pipeline[each.key]
  id       = "${var.role.name}:${each.key}"
}

import {
  for_each = var.import_existing ? var.role.managed_policy_arns : toset([])
  to       = aws_iam_role_policy_attachment.pipeline[each.value]
  id       = "${var.role.name}/${each.value}"
}

import {
  for_each = var.log_group == null || !var.import_existing ? toset([]) : toset(["/aws/lambda/${var.function_name}"])
  to       = aws_cloudwatch_log_group.pipeline[0]
  id       = each.value
}

import {
  for_each = local.import_one
  to       = aws_s3_bucket_notification.transcripts
  id       = var.bucket_name
}

import {
  for_each = local.import_one
  to       = aws_s3_bucket_policy.transcripts
  id       = var.bucket_name
}

import {
  for_each = local.import_one
  to       = aws_kms_key_policy.transcripts
  id       = var.kms_key_id
}

locals {
  # One element when importing, none otherwise: lets the single-resource imports be switched off.
  import_one = var.import_existing ? toset(["import"]) : toset([])
}
