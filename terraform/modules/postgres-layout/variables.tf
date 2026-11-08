variable "host" {
  description = "Shared PostgreSQL writer endpoint. No URL, user or credential."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$", var.host)) && length(var.host) <= 253
    error_message = "host must be a DNS name or IPv4 host without whitespace, URL delimiters, credentials or a port."
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
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database)) && !contains(["postgres", "template0", "template1", "rdsadmin"], var.database)
    error_message = "database must be a lowercase application identifier of at most 63 characters, not a maintenance database."
  }
}

variable "forbidden_roles" {
  description = "Administrator/bootstrap identities forbidden in service bindings. Roots must include their configured database master username."
  type        = set(string)
  nullable    = false
  default     = ["relay_admin"]
}

variable "services" {
  nullable    = false
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
    history   = { schema = "relayhistory", migration_role = "history_owner", runtime_role = "relayhistory_runtime" }
    relayfile = { schema = "relayfile", migration_role = "relayfile_owner", runtime_role = "relayfile_runtime" }
  }
  validation {
    condition     = length(var.services) > 0
    error_message = "services must contain at least one explicitly named component."
  }
  validation {
    condition     = alltrue([for name in keys(var.services) : can(regex("^[a-z][a-z0-9_-]*$", name))])
    error_message = "Service keys must start with a lowercase letter and contain only lowercase letters, digits, underscores or hyphens."
  }
  validation {
    condition = alltrue(flatten([for service in values(var.services) : [
      for identifier in [service.schema, service.migration_role, service.runtime_role] :
      can(regex("^[a-z][a-z0-9_]{0,62}$", identifier)) && !startswith(identifier, "pg_") && !startswith(identifier, "rds_") && !contains(["public", "information_schema", "postgres", "rdsadmin", "rdstopmgr"], identifier)
    ]]))
    error_message = "Schemas and roles must be bounded service identifiers, never public/platform/administrator identities."
  }
  validation {
    condition     = alltrue(flatten([for service in values(var.services) : [for role in [service.migration_role, service.runtime_role] : !contains(var.forbidden_roles, role)]]))
    error_message = "Service roles must not reuse any configured database administrator/bootstrap identity."
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
