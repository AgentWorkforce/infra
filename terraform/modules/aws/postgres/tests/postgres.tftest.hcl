mock_provider "random" {}

mock_provider "aws" {
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "relay.abc123.us-west-2.rds.amazonaws.com"
      arn                = "arn:aws:rds:us-west-2:111111111111:db:relay"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds!db-1", kms_key_id = "", secret_status = "active" }]
    }
  }
  mock_resource "aws_rds_cluster" {
    defaults = {
      endpoint           = "relay.cluster-abc123.us-west-2.rds.amazonaws.com"
      reader_endpoint    = "relay.cluster-ro-abc123.us-west-2.rds.amazonaws.com"
      arn                = "arn:aws:rds:us-west-2:111111111111:cluster:relay"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds!cluster-1", kms_key_id = "", secret_status = "active" }]
    }
  }
}

variables {
  name                   = "relay"
  subnet_ids             = ["subnet-a", "subnet-b"]
  vpc_security_group_ids = ["sg-db"]
}

run "rds_defaults_are_secure" {
  command = apply

  assert {
    condition     = aws_db_instance.this[0].publicly_accessible == false
    error_message = "The instance must not be publicly accessible."
  }
  assert {
    condition     = aws_db_instance.this[0].storage_encrypted
    error_message = "Storage must be encrypted."
  }
  assert {
    condition     = aws_db_instance.this[0].manage_master_user_password
    error_message = "The master password must be RDS-managed (Secrets Manager), never in state."
  }
  assert {
    condition     = aws_db_instance.this[0].password == null && aws_db_instance.this[0].password_wo == null
    error_message = "No password may be passed to the instance."
  }
  assert {
    condition     = aws_db_instance.this[0].deletion_protection && !aws_db_instance.this[0].skip_final_snapshot
    error_message = "Deletion protection and a final snapshot are on by default."
  }
  assert {
    condition     = aws_db_instance.this[0].backup_retention_period >= 7
    error_message = "Backups (and PITR) are on by default."
  }
  assert {
    condition     = aws_db_instance.this[0].multi_az
    error_message = "Multi-AZ is on by default."
  }
  assert {
    condition     = one([for p in aws_db_parameter_group.this[0].parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "rds.force_ssl must be 1 by default."
  }
  assert {
    condition     = aws_db_parameter_group.this[0].family == "postgres17"
    error_message = "Default engine is PostgreSQL 17."
  }
  assert {
    condition     = length(aws_rds_cluster.this) == 0
    error_message = "rds mode creates no Aurora cluster."
  }
  assert {
    condition     = output.master_user_secret_arn == "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds!db-1"
    error_message = "The managed secret ARN is the output."
  }
}

run "allowed_extensions_always_include_pg_trgm_and_vector" {
  command = plan

  variables {
    allowed_extensions = ["pgcrypto"]
  }

  assert {
    condition     = toset(split(",", one([for p in aws_db_parameter_group.this[0].parameter : p.value if p.name == "rds.allowed_extensions"]))) == toset(["pgcrypto", "pg_trgm", "vector"])
    error_message = "pg_trgm and vector must be appended to rds.allowed_extensions."
  }
}

run "aurora_mode" {
  command = apply

  variables {
    engine_mode    = "aurora"
    engine_version = "17.5"
  }

  assert {
    condition     = length(aws_db_instance.this) == 0 && length(aws_rds_cluster_instance.this) == 2
    error_message = "aurora mode creates a cluster with two instances by default."
  }
  assert {
    condition     = aws_rds_cluster.this[0].storage_encrypted && aws_rds_cluster.this[0].manage_master_user_password && aws_rds_cluster.this[0].deletion_protection
    error_message = "Aurora defaults: encrypted, managed password, deletion protection."
  }
  assert {
    condition     = alltrue([for i in aws_rds_cluster_instance.this : i.publicly_accessible == false])
    error_message = "Aurora instances must not be public."
  }
  assert {
    condition     = aws_rds_cluster_parameter_group.this[0].family == "aurora-postgresql17"
    error_message = "Aurora family follows the major version."
  }
}

run "aurora_needs_full_version" {
  command = plan

  variables {
    engine_mode    = "aurora"
    engine_version = "17"
  }

  expect_failures = [aws_rds_cluster.this]
}

run "security_groups_required" {
  command = plan

  variables {
    vpc_security_group_ids = []
  }

  expect_failures = [var.vpc_security_group_ids]
}

run "backups_cannot_be_disabled" {
  command = plan

  variables {
    backup_retention_days = 0
  }

  expect_failures = [var.backup_retention_days]
}

run "one_subnet_is_refused" {
  command = plan

  variables {
    subnet_ids = ["subnet-a"]
  }

  expect_failures = [aws_db_subnet_group.this]
}

run "managed_parameters_cannot_be_repeated" {
  command = plan

  variables {
    parameters = [{ name = "rds.force_ssl", value = "0" }]
  }

  expect_failures = [var.parameters]
}

run "aurora_monitoring_needs_a_role" {
  command = plan

  variables {
    engine_mode         = "aurora"
    engine_version      = "17.9"
    monitoring_interval = 60
  }

  expect_failures = [aws_rds_cluster_instance.this]
}

run "allowed_extensions_parameter_cannot_be_repeated" {
  command = plan

  variables {
    parameters = [{ name = "rds.allowed_extensions", value = "pgcrypto" }]
  }

  expect_failures = [var.parameters]
}

run "parameter_count_capped" {
  command = plan

  variables {
    parameters = [for i in range(19) : { name = "custom.p${i}", value = "1" }]
  }

  expect_failures = [var.parameters]
}
