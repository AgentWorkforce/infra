variables {
  host     = "shared.example.rds.amazonaws.com"
  database = "relaycontrol"
}

run "one_database_isolated_services" {
  command = plan
  assert {
    condition     = alltrue([for binding in values(output.bindings) : binding.host == var.host && binding.database == var.database && binding.port == 5432 && binding.sslmode == "verify-full"])
    error_message = "Every service must target the same verified-TLS writer/database."
  }
  assert {
    condition     = output.bindings.control.schema != output.bindings.hoopdb.schema && output.bindings.relaycast.schema == "relaycast"
    error_message = "Control and HoopDb must be separate schemas; Relaycast belongs in the shared PostgreSQL database."
  }
  assert {
    condition     = !output.topology.application_sql_ready
    error_message = "Binding validation must not claim SQL bootstrap or application compatibility."
  }
}

run "same_binding_contract_can_move_one_service_later" {
  command = plan
  variables {
    host     = "future-separate.example.rds.amazonaws.com"
    database = "moved"
    services = {
      hoopdb = { schema = "sessions", migration_role = "hoop", runtime_role = "sessions_pipeline_runtime" }
    }
  }
  assert {
    condition     = length(output.bindings) == 1 && output.bindings.hoopdb.schema == "sessions" && output.bindings.hoopdb.database == "moved" && output.bindings.hoopdb.host == "future-separate.example.rds.amazonaws.com"
    error_message = "A later split must preserve the service schema/binding shape and change only its explicit target."
  }
}

run "schema_collision_refused" {
  command = plan
  variables {
    services = {
      control = { schema = "shared", migration_role = "control_owner", runtime_role = "control_runtime" }
      hoopdb  = { schema = "shared", migration_role = "hoop_owner", runtime_role = "hoop_runtime" }
    }
  }
  expect_failures = [var.services]
}

run "shared_migration_owner_refused" {
  command = plan
  variables {
    services = {
      control = { schema = "control", migration_role = "shared_owner", runtime_role = "control_runtime" }
      hoopdb  = { schema = "sessions", migration_role = "shared_owner", runtime_role = "hoop_runtime" }
    }
  }
  expect_failures = [var.services]
}

run "owner_as_runtime_refused" {
  command = plan
  variables {
    services = { control = { schema = "control", migration_role = "owner", runtime_role = "owner" } }
  }
  expect_failures = [var.services]
}

run "public_schema_refused" {
  command = plan
  variables {
    services = { control = { schema = "public", migration_role = "control_owner", runtime_role = "control_runtime" } }
  }
  expect_failures = [var.services]
}

run "platform_role_refused" {
  command = plan
  variables {
    services = { control = { schema = "control", migration_role = "control_owner", runtime_role = "rds_superuser" } }
  }
  expect_failures = [var.services]
}

run "maintenance_database_refused" {
  command = plan
  variables { database = "postgres" }
  expect_failures = [var.database]
}
