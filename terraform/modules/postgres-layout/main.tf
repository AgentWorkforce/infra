locals {
  # Keep complete connection identity per service even while every endpoint is
  # the same. A future split can move one binding without renaming its schema.
  bindings = {
    for name, service in var.services : name => {
      host           = var.host
      port           = var.port
      database       = var.database
      schema         = service.schema
      migration_role = service.migration_role
      runtime_role   = service.runtime_role
      sslmode        = "verify-full"
    }
  }
}
