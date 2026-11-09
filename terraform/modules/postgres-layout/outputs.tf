output "bindings" {
  description = "Non-secret per-service connection identity. Databases, roles and schemas require reviewed bootstrap and compatible application support before use."
  value       = local.bindings
}

output "topology" {
  description = "Required relational topology, not live application acceptance."
  value = {
    mode                  = length(var.service_databases) > 0 ? "shared-instance-isolated-databases" : "shared-database-isolated-schemas"
    host                  = var.host
    port                  = var.port
    database              = length(var.service_databases) == 0 ? var.database : null
    initial_database      = var.database
    service_databases     = { for name, binding in local.bindings : name => binding.database }
    service_count         = length(var.services)
    application_sql_ready = false
  }
}
