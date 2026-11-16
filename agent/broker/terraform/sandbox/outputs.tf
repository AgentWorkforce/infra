output "broker_role_arn" {
  description = "Configure the broker host's aws-cred-broker profile with this role_arn."
  value       = module.broker_role.role_arn
}

output "sandbox_scoped_role_arn" {
  description = "Must equal broker/allowlist.json accounts.805532413586.roles.scoped."
  value       = module.sandbox_scoped_role.role_arn
}

output "agent_hosts_elevated_role_arn" {
  description = "Must equal broker/allowlist.json accounts.<broker account>.roles.elevated."
  value       = module.agent_hosts_elevated_role.role_arn
}
