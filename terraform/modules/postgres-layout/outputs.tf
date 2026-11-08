output "bindings" {
  description = "Non-secret per-service connection identity. Roles and schemas require reviewed bootstrap and schema-aware application support before use."
  value       = local.bindings
}

output "topology" {
  description = "Required relational topology, not live application acceptance."
  value = {
    mode                  = "shared-database-isolated-schemas"
    host                  = var.host
    port                  = var.port
    database              = var.database
    service_count         = length(var.services)
    application_sql_ready = false
  }
}
