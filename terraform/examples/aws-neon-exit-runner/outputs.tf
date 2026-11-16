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
  value = aws_subnet.private.id
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "ssm_session_command" {
  description = "Shell on the runner for a principal allowed ssm:StartSession on it."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.runner.id}"
}
