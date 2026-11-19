output "instance_id" {
  description = "Runner instance id (target of ssm start-session)."
  value       = aws_instance.runner.id
}

output "runner_role_arn" {
  description = "Instance role: SSM core plus read of the target secret."
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

output "private_subnet_id" {
  description = "Id of the private subnet the runner instance launches in."
  value       = aws_subnet.private.id
}

output "nat_gateway_id" {
  description = "Id of the NAT gateway that gives the private subnet outbound access."
  value       = aws_nat_gateway.this.id
}

output "security_group_id" {
  description = "Id of the runner security group (no ingress; HTTPS egress only)."
  value       = aws_security_group.this.id
}

output "ssm_session_command" {
  description = "Shell on the runner for a principal allowed ssm:StartSession on it."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.runner.id}"
}
