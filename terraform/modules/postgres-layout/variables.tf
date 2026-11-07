variable "host" {
  description = "Shared PostgreSQL writer endpoint. No URL, user or credential."
  type        = string
  nullable    = false
  validation {
    condition     = length(trimspace(var.host)) > 0 && !strcontains(var.host, "://") && !strcontains(var.host, "@")
    error_message = "host must be a nonempty endpoint, not a connection URL or credential."
  }
}

variable "port" {
  description = "Shared PostgreSQL port."
  type        = number
  nullable    = false
  default     = 5432
  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be an integer between 1 and 65535."
  }
}

variable "database" {
  description = "The single application database used by every service binding. Preserve an existing database name; changing RDS db_name may replace infrastructure."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database)) && !contains(["postgres", "template0", "template1"], var.database)
    error_message = "database must be a lowercase application identifier of at most 63 characters, not a maintenance database."
  }
}

variable "services" {
  description = "Per-service target schemas and independent owner/runtime roles. This is a non-secret binding contract; it does not create SQL objects, change app migrations or prove runtime support."
  type = map(object({
    schema         = string
    migration_role = string
    runtime_role   = string
  }))
  default = {
    control   = { schema = "relaycontrol", migration_role = "control_owner", runtime_role = "control_api_runtime" }
    hoopdb    = { schema = "sessions", migration_role = "hoop", runtime_role = "sessions_pipeline_runtime" }
    relaycast = { schema = "relaycast", migration_role = "relaycast_owner", runtime_role = "relaycast_runtime" }
    history   = { schema = "relayhistory", migration_role = "history_owner", runtime_role = "history_runtime" }
    relayfile = { schema = "relayfile", migration_role = "relayfile_owner", runtime_role = "relayfile_runtime" }
  }
  validation {
    condition     = length(var.services) > 0 && alltrue([for name in keys(var.services) : can(regex("^[a-z][a-z0-9_-]*$", name))])
    error_message = "services must contain at least one explicitly named component."
  }
  validation {
    condition = alltrue(flatten([for service in values(var.services) : [
      for identifier in [service.schema, service.migration_role, service.runtime_role] :
      can(regex("^[a-z][a-z0-9_]{0,62}$", identifier)) && !startswith(identifier, "pg_") && !contains(["public", "information_schema", "postgres", "rdsadmin", "rds_superuser"], identifier)
    ]]))
    error_message = "Schemas and roles must be bounded service identifiers, never public/platform/administrator identities."
  }
  validation {
    condition     = length(distinct([for service in values(var.services) : service.schema])) == length(var.services)
    error_message = "Each service must own a distinct schema."
  }
  validation {
    condition     = length(distinct(flatten([for service in values(var.services) : [service.migration_role, service.runtime_role]]))) == 2 * length(var.services)
    error_message = "Each service needs its own migration owner and runtime role; no role may be shared across components or duties."
  }
}
