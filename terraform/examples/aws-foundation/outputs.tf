output "data_environment_inputs" {
  description = "Non-secret subset of inputs for a separately initialized aws-environments state."
  value = {
    name_prefix                 = var.name_prefix
    release_name                = var.release_name
    pippen                      = var.pippen
    account_id                  = module.foundation.account_id
    region                      = module.foundation.region
    environment                 = module.foundation.environment
    private_subnet_ids          = module.foundation.private_subnet_ids
    database_security_group_ids = module.foundation.database_security_group_ids
    search_subnet_ids           = module.foundation.search_subnet_ids
    search_security_group_ids   = module.foundation.search_security_group_ids
    function_security_group_ids = module.foundation.function_security_group_ids
    eks_cluster_name            = module.foundation.eks_cluster_name
    namespace                   = module.foundation.namespace
  }
}
output "identity_references" {
  description = "References for separately owned workload roles."
  value       = module.foundation.identity_references
}
output "actor_profile" {
  description = "First-party durable-actors placement/sandbox values."
  value       = module.foundation.actor_profile
}
output "storage_class_manifest" {
  description = "Retained encrypted CSI class to apply in application state."
  value       = module.foundation.storage_class_manifest
}
output "cluster_security_group_id" {
  description = "Service-created SG identifier for scoped retirement inventory."
  value       = module.foundation.cluster_security_group_id
}
output "load_balancer_controller" {
  description = "Helm install references for the AWS Load Balancer Controller; null while disabled."
  value       = module.foundation.load_balancer_controller
}
