locals {
  # Keep complete connection identity per service even while every endpoint is
  # the same. Databases are isolated when explicitly selected; the empty map preserves
  # the old shared-database contract without silently reinterpreting existing callers.
  bindings = {
    for name, service in var.services : name => {
      host           = var.host
      port           = var.port
      database       = lookup(var.service_databases, name, var.database)
      schema         = service.schema
      migration_role = service.migration_role
      runtime_role   = service.runtime_role
      sslmode        = "verify-full"
    }
  }
}
