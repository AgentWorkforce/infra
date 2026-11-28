output "queue_url" {
  description = "session-events queue URL."
  value       = aws_sqs_queue.events.id
}

output "event_source_mapping_max_concurrency" {
  description = "The mapping's MaximumConcurrency as planned."
  value       = var.max_concurrency
}

output "schedules" {
  description = "Schedule rule names and states."
  value       = { for k, r in aws_cloudwatch_event_rule.schedule : k => { name = r.name, state = r.state } }
}
