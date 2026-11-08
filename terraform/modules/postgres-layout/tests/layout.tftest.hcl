variables {
  host     = "shared.example.rds.amazonaws.com"
  database = "relaycontrol"
}

run "one_database_isolated_services" {
  command = plan
  assert {
    condition     = toset(keys(output.bindings)) == toset(["control", "hoopdb", "relaycast", "history", "relayfile"]) && alltrue([for name, binding in output.bindings : binding == { host = var.host, database = var.database, port = var.port, sslmode = "verify-full", schema = var.services[name].schema, migration_role = var.services[name].migration_role, runtime_role = var.services[name].runtime_role }])
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
    condition     = length(output.bindings) == 1 && output.bindings.hoopdb == { schema = "sessions", migration_role = "hoop", runtime_role = "sessions_pipeline_runtime", database = "moved", host = "future-separate.example.rds.amazonaws.com", port = 5432, sslmode = "verify-full" }
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

run "default_admin_owner_refused" {
  command = plan
  variables { services = { control = { schema = "control", migration_role = "relay_admin", runtime_role = "control_runtime" } } }
  expect_failures = [var.services]
}

run "default_admin_runtime_refused" {
  command = plan
  variables { services = { control = { schema = "control", migration_role = "control_owner", runtime_role = "relay_admin" } } }
  expect_failures = [var.services]
}

run "rds_iam_refused" {
  command = plan
  variables { services = { control = { schema = "control", migration_role = "control_owner", runtime_role = "rds_iam" } } }
  expect_failures = [var.services]
}

run "rds_password_refused" {
  command = plan
  variables { services = { control = { schema = "control", migration_role = "control_owner", runtime_role = "rds_password" } } }
  expect_failures = [var.services]
}

run "rds_replication_refused" {
  command = plan
  variables { services = { control = { schema = "control", migration_role = "control_owner", runtime_role = "rds_replication" } } }
  expect_failures = [var.services]
}

run "rdstopmgr_refused" {
  command = plan
  variables { services = { control = { schema = "control", migration_role = "control_owner", runtime_role = "rdstopmgr" } } }
  expect_failures = [var.services]
}

run "configured_master_refused" {
  command = plan
  variables {
    forbidden_roles = ["customer_master"]
    services        = { control = { schema = "control", migration_role = "customer_master", runtime_role = "control_runtime" } }
  }
  expect_failures = [var.services]
}
run "rds_maintenance_database_refused" {
  command = plan
  variables { database = "rdsadmin" }
  expect_failures = [var.database]
}
run "null_services_uses_nonnull_default" {
  command = plan
  variables { services = null }
  assert {
    condition     = length(output.bindings) == 5
    error_message = "Non-nullable services must safely normalize null to the explicit default."
  }
}

run "invalid_host_0_refused" {
  command = plan
  variables { host = "host/path" }
  expect_failures = [var.host]
}

run "invalid_host_1_refused" {
  command = plan
  variables { host = "host?query" }
  expect_failures = [var.host]
}

run "invalid_host_2_refused" {
  command = plan
  variables { host = "host#fragment" }
  expect_failures = [var.host]
}

run "invalid_host_3_refused" {
  command = plan
  variables { host = "host:5432" }
  expect_failures = [var.host]
}

run "invalid_host_4_refused" {
  command = plan
  variables { host = " space" }
  expect_failures = [var.host]
}

run "invalid_host_5_refused" {
  command = plan
  variables { host = "a..b" }
  expect_failures = [var.host]
}
