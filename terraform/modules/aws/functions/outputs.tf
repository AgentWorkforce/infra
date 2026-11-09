output "activation_enabled" {
  description = "Whether automatic queue consumption and schedules are enabled."
  value       = var.enabled
}

output "function_name" {
  description = "Pipeline function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Pipeline function ARN."
  value       = aws_lambda_function.this.arn
}

output "execution_role_arn" {
  description = "Actual Lambda execution role ARN, managed here or supplied by the operator."
  value       = local.execution_role_arn
}

output "queue_url" {
  description = "session-events queue URL (SESSION_PIPELINE_QUEUE_URL)."
  value       = aws_sqs_queue.events.url
}

output "queue_arn" {
  description = "session-events queue ARN."
  value       = aws_sqs_queue.events.arn
}

output "dlq_arn" {
  description = "Dead-letter queue ARN."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "Dead-letter queue URL (inspect and redrive from here)."
  value       = aws_sqs_queue.dlq.url
}

output "secret_arn" {
  description = "Pipeline secret ARN (SESSION_PIPELINE_SECRET_ARN). Set its JSON value out of band: the HoopDb URL (the same value as the chart's HOOPDB_URL key) and the search backend credentials."
  value       = local.secret_arn
}

output "bucket_notification_queue_configuration" {
  description = "The S3 notification queue configuration, for buckets whose notifications are managed elsewhere (manage_bucket_notification = false)."
  value = {
    id            = "${var.name}-session-pipeline-manifests"
    queue_arn     = aws_sqs_queue.events.arn
    events        = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix = "${local.key_prefix}/"
    filter_suffix = "/manifest.json"
  }
}

output "reconcile_rule_arn" {
  description = "EventBridge reconcile rule ARN."
  value       = aws_cloudwatch_event_rule.reconcile.arn
}

output "brief_rule_arn" {
  description = "EventBridge brief rule ARN (DISABLED unless briefs_enabled)."
  value       = aws_cloudwatch_event_rule.brief.arn
}

output "execution_role_policy_json" {
  description = "Proposed runtime permissions, including additional_policy_statements. Attached only in managed-role mode; external-role installation and validation belong to the operator. May contain values unknown until resources exist."
  value       = jsonencode({ Version = "2012-10-17", Statement = local.role_statements })
}
