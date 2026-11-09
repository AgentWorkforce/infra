locals {
  aurora        = var.engine_mode == "aurora"
  major_version = split(".", var.engine_version)[0]
  family        = local.aurora ? "aurora-postgresql${local.major_version}" : "postgres${local.major_version}"

  create_subnet_group = var.db_subnet_group_name == null
  subnet_group_name   = local.create_subnet_group ? aws_db_subnet_group.this[0].name : var.db_subnet_group_name

  # pg_trgm and vector are always allowed: RelayHistory runs CREATE EXTENSION for both.
  allowed_extensions = var.allowed_extensions == null ? [] : distinct(concat(var.allowed_extensions, ["pg_trgm", "vector"]))

  parameters = concat(
    [{ name = "rds.force_ssl", value = var.force_ssl ? "1" : "0", apply_method = "pending-reboot" }],
    length(local.allowed_extensions) > 0 ? [{ name = "rds.allowed_extensions", value = join(",", local.allowed_extensions), apply_method = "immediate" }] : [],
    var.parameters,
  )
}

# A unique final snapshot name per database lifetime, so destroying a
# recreated database never collides with an earlier final snapshot.
resource "random_id" "final_snapshot" {
  keepers = {
    name        = var.name
    engine_mode = var.engine_mode
  }
  byte_length = 4
}

resource "aws_db_subnet_group" "this" {
  count = local.create_subnet_group ? 1 : 0

  name        = var.name
  description = "agent-relay Postgres ${var.name}"
  subnet_ids  = var.subnet_ids
  tags        = var.tags

  lifecycle {
    precondition {
      condition     = length(var.subnet_ids) >= 2
      error_message = "Pass at least two private subnet_ids in different AZs, or an existing db_subnet_group_name."
    }
  }
}

# ---------------------------------------------------------------------------
# RDS for PostgreSQL
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  count = local.aurora ? 0 : 1

  name        = var.name
  family      = local.family
  description = "agent-relay Postgres ${var.name}"
  tags        = var.tags

  dynamic "parameter" {
    for_each = local.parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_118:Enhanced Monitoring needs a monitoring role; opt in with monitoring_interval and monitoring_role_arn.
  count = local.aurora ? 0 : 1

  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class
  db_name        = var.database_name
  port           = var.port

  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = local.subnet_group_name
  vpc_security_group_ids = var.vpc_security_group_ids
  publicly_accessible    = false
  network_type           = "IPV4"
  ca_cert_identifier     = var.ca_cert_identifier
  parameter_group_name   = aws_db_parameter_group.this[0].name
  multi_az               = var.multi_az

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  iops                  = var.iops
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  backup_retention_period   = var.backup_retention_days
  backup_window             = var.preferred_backup_window
  maintenance_window        = var.preferred_maintenance_window
  copy_tags_to_snapshot     = var.copy_tags_to_snapshot
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-${random_id.final_snapshot.hex}"
  delete_automated_backups  = false

  auto_minor_version_upgrade          = var.auto_minor_version_upgrade
  allow_major_version_upgrade         = false
  apply_immediately                   = var.apply_immediately
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  enabled_cloudwatch_logs_exports     = var.enabled_cloudwatch_logs_exports

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? var.monitoring_role_arn : null

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.monitoring_interval == 0 || var.monitoring_role_arn != null
      error_message = "monitoring_interval > 0 needs monitoring_role_arn."
    }
  }
}

# ---------------------------------------------------------------------------
# Aurora PostgreSQL
# ---------------------------------------------------------------------------

resource "aws_rds_cluster_parameter_group" "this" {
  count = local.aurora ? 1 : 0

  name        = var.name
  family      = local.family
  description = "agent-relay Aurora Postgres ${var.name}"
  tags        = var.tags

  dynamic "parameter" {
    for_each = local.parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "this" {
  #checkov:skip=CKV2_AWS_8:Automated backups and PITR are on; AWS Backup plans are an account-level choice.
  #checkov:skip=CKV2_AWS_27:Statement logging would log transcript-bearing SQL; opt in with parameters (log_statement).
  count = local.aurora ? 1 : 0

  cluster_identifier = var.name
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = var.engine_version
  database_name      = var.database_name
  port               = var.port

  master_username               = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name            = local.subnet_group_name
  vpc_security_group_ids          = var.vpc_security_group_ids
  network_type                    = "IPV4"
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this[0].name

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = var.preferred_backup_window
  preferred_maintenance_window = var.preferred_maintenance_window
  copy_tags_to_snapshot        = var.copy_tags_to_snapshot
  deletion_protection          = var.deletion_protection
  skip_final_snapshot          = var.skip_final_snapshot
  final_snapshot_identifier    = var.skip_final_snapshot ? null : "${var.name}-final-${random_id.final_snapshot.hex}"
  delete_automated_backups     = false

  allow_major_version_upgrade         = false
  apply_immediately                   = var.apply_immediately
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  enabled_cloudwatch_logs_exports     = var.enabled_cloudwatch_logs_exports

  dynamic "serverlessv2_scaling_configuration" {
    for_each = var.instance_class == "db.serverless" ? [var.serverlessv2_scaling] : []
    content {
      min_capacity = serverlessv2_scaling_configuration.value.min_capacity
      max_capacity = serverlessv2_scaling_configuration.value.max_capacity
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version))
      error_message = "Aurora needs a full engine_version such as \"17.5\" (aws rds describe-db-engine-versions --engine aurora-postgresql)."
    }
  }
}

resource "aws_rds_cluster_instance" "this" {
  #checkov:skip=CKV_AWS_118:Enhanced Monitoring needs a monitoring role; opt in with monitoring_interval and monitoring_role_arn.
  count = local.aurora ? var.aurora_instance_count : 0

  identifier         = "${var.name}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this[0].id
  engine             = aws_rds_cluster.this[0].engine
  engine_version     = aws_rds_cluster.this[0].engine_version
  instance_class     = var.instance_class

  db_subnet_group_name       = local.subnet_group_name
  publicly_accessible        = false
  ca_cert_identifier         = var.ca_cert_identifier
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately
  copy_tags_to_snapshot      = var.copy_tags_to_snapshot

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? var.monitoring_role_arn : null

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.monitoring_interval == 0 || var.monitoring_role_arn != null
      error_message = "monitoring_interval > 0 needs monitoring_role_arn."
    }
  }
}
