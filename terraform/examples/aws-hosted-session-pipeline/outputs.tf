output "queue_url" {
  description = "session-events queue URL."
  value       = module.pipeline.queue_url
}

output "event_source_mapping_max_concurrency" {
  description = "The mapping's MaximumConcurrency as planned."
  value       = var.max_concurrency
}

output "optional_schedules" {
  description = "Optional schedule rule names and states (reconcile and brief live in the module)."
  value       = { for k, r in aws_cloudwatch_event_rule.schedule : k => { name = r.name, state = r.state } }
}
