output "instance_id" {
  description = "Runner instance id (target of ssm start-session)."
  value       = aws_instance.runner.id
}

output "runner_role_arn" {
  description = "Instance role: SSM core plus read of the two exit secrets."
  value       = aws_iam_role.runner.arn
}

output "db_owner_secret_arn" {
  description = "Secrets Manager ARN of the empty target credential."
  value       = aws_secretsmanager_secret.db_owner.arn
}

output "db_owner_secret_name" {
  description = "Secrets Manager name of the target credential."
  value       = aws_secretsmanager_secret.db_owner.name
}

output "copy_urls_secret_arn" {
  description = "Secrets Manager ARN of the empty Cloud copy URLs secret."
  value       = aws_secretsmanager_secret.copy_urls.arn
}

output "copy_urls_secret_name" {
  description = "Secrets Manager name of the Cloud copy URLs secret."
  value       = aws_secretsmanager_secret.copy_urls.name
}

output "private_subnet_id" {
  description = "Private subnet the runner sits in."
  value       = aws_subnet.private.id
}

output "nat_gateway_id" {
  description = "NAT gateway that carries the runner's egress."
  value       = aws_nat_gateway.this.id
}

output "security_group_id" {
  description = "Runner security group (no ingress)."
  value       = aws_security_group.this.id
}

output "ssm_session_command" {
  description = "Shell on the runner for a principal allowed ssm:StartSession on it."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.runner.id}"
}

output "alerts_topic_arn" {
  description = "Ops SNS topic the alarms publish to; subscribe the pager here (or set alert_endpoint)."
  value       = aws_sns_topic.alerts.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group that receives the files listed in runner_log_files."
  value       = aws_cloudwatch_log_group.runner.name
}

output "runner_log_dir" {
  description = "Directory on the runner that holds the shipped log files (runner_log_files)."
  value       = var.runner_log_dir
}

output "runner_log_files" {
  description = "File names under runner_log_dir that are shipped; a new file name must be added to runner_log_files."
  value       = var.runner_log_files
}

output "alarm_names" {
  description = "Alarms: one per alert_signals entry, plus the dead-man alarm when heartbeat_enabled."
  value       = concat([for a in aws_cloudwatch_metric_alarm.signal : a.alarm_name], [for a in aws_cloudwatch_metric_alarm.heartbeat : a.alarm_name])
}

output "cloudwatch_agent_association_id" {
  description = "SSM association that installs and configures the CloudWatch agent (re-run with aws ssm start-associations-once)."
  value       = aws_ssm_association.cloudwatch_agent.association_id
}
