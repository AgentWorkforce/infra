output "instance_id" {
  description = "Target for aws ssm start-session."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private address of the host. It accepts no inbound connections."
  value       = aws_instance.this.private_ip
}

output "role_arn" {
  description = "Instance role: SSM core plus read of the worker token secret."
  value       = aws_iam_role.this.arn
}

output "security_group_id" {
  description = "Security group with no inbound rules and outbound HTTPS only."
  value       = aws_security_group.this.id
}

output "worker_token_secret_arn" {
  description = "Secret holding the bridge's Relay token. Terraform creates it empty; the value is written out of band and never enters state."
  value       = aws_secretsmanager_secret.worker_token.arn
}
