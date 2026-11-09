output "proof_contract" {
  description = "Nonsecret immutable domain/external prerequisite identity; plan caller is explicitly not apply evidence."
  value = {
    account_id            = var.account_id, region = var.region, lease = var.pippen, source_sha = var.source_sha,
    domain_name           = module.search.domain_name, domain_arn = module.search.domain_arn, endpoint = module.search.endpoint,
    disposable            = true, tags = local.tags, roles = var.roles,
    vpc_id                = var.vpc_id, subnet_ids = var.subnet_ids, security_group_ids = [var.domain_security_group_id], client_security_group_ids = var.client_security_group_ids,
    plan_caller_arn       = data.aws_caller_identity.plan.arn, expected_apply_caller_arn = local.control_caller, expected_apply_role_arn = local.control_role,
    created_iam_resources = 0, created_network_resources = 0
  }
}
