output "arn" {
  description = "The log group's ARN (without the trailing :*)."
  value       = aws_cloudwatch_log_group.audit.arn
}

output "name" {
  description = "The log group's name."
  value       = aws_cloudwatch_log_group.audit.name
}
