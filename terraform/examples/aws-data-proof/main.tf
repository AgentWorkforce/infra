data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_subnet" "private_first" {
  count = var.private_subnet_ids == null ? 0 : 1
  id    = sort(tolist(var.private_subnet_ids))[0]
}
data "aws_subnet" "private_second" {
  count = var.private_subnet_ids == null ? 0 : 1
  id    = sort(tolist(var.private_subnet_ids))[1]
}
data "aws_subnet" "host" { id = var.host_subnet_id }
data "aws_ami" "host" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}
locals {
  private_subnets = var.private_subnet_ids == null ? [] : [data.aws_subnet.private_first[0], data.aws_subnet.private_second[0]]
  private_ids     = var.private_subnet_ids == null ? concat(aws_subnet.private_first[*].id, aws_subnet.private_second[*].id) : sort(tolist(var.private_subnet_ids))
  name            = "pippen-sbx-${var.run_id}"
  bucket          = "${local.name}-${var.account_id}-${var.region}"
  prefix          = "fixture/${var.pippen.session_id}/"
  phase           = var.restore_checkpoint == null ? "seed" : "restore"
  boundary        = "arn:aws:iam::${var.account_id}:policy/pippen-agent-session-boundary"
  marker          = sha256("${var.source_sha}:${var.pippen.session_id}:${var.run_id}")
  payload         = "transport/sha256-${var.payload_sha256}.tar.gz"
  receipt         = "receipts/${local.phase}.json"
  tags            = { "pippen:sandbox" = "true", "pippen:agent" = var.pippen.agent, "pippen:session" = var.pippen.session_id, "proof:run" = var.run_id, "proof:source" = var.source_sha, ManagedBy = "terraform" }
}
resource "terraform_data" "guard" {
  input = { account = var.account_id, lease = var.pippen.session_id, source = var.source_sha }
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id && data.aws_region.current.region == var.region && data.aws_caller_identity.current.arn == "arn:aws:sts::${var.account_id}:assumed-role/agent-session/agent-${var.pippen.session_id}"
      error_message = "Refuse a different account, region or allocated Pippen caller."
    }
    precondition {
      condition     = (var.private_subnet_ids == null) != (var.create_private_subnets == null)
      error_message = "Select exactly one of existing private_subnet_ids or create_private_subnets."
    }
    precondition {
      condition     = (var.private_subnet_ids == null ? true : alltrue([for subnet in local.private_subnets : subnet.owner_id == var.account_id && subnet.vpc_id == var.vpc_id && !subnet.map_public_ip_on_launch]) && length(toset([for subnet in local.private_subnets : subnet.availability_zone])) == 2 && !contains(var.private_subnet_ids, var.host_subnet_id)) && data.aws_subnet.host.owner_id == var.account_id && data.aws_subnet.host.vpc_id == var.vpc_id
      error_message = "Require reviewed distinct private AZ subnets and separate host subnet in the same account/VPC. Route review remains external."
    }
    precondition {
      condition     = data.aws_ami.host.architecture == "arm64" && data.aws_ami.host.root_device_type == "ebs" && data.aws_ami.host.virtualization_type == "hvm" && startswith(data.aws_ami.host.name, "al2023-ami-")
      error_message = "Require the pinned Amazon AL2023 ARM64 EBS/HVM AMI."
    }
    precondition {
      condition     = length(local.bucket) <= 63
      error_message = "Derived bucket name exceeds the S3 limit."
    }
  }
}
resource "aws_security_group" "database" {
  name        = "${local.name}-pg"
  description = "Owned module proof PostgreSQL; ingress only from owned verifier"
  vpc_id      = var.vpc_id
  tags        = local.tags
  depends_on  = [terraform_data.guard]
}
resource "aws_security_group" "verifier" {
  name        = "${local.name}-verifier"
  description = "Owned module proof host; no ingress"
  vpc_id      = var.vpc_id
  tags        = local.tags
  depends_on  = [terraform_data.guard]
}
resource "aws_vpc_security_group_ingress_rule" "database" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.verifier.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Owned verifier only"
  tags                         = local.tags
}
resource "aws_vpc_security_group_egress_rule" "database" {
  security_group_id            = aws_security_group.verifier.id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Owned database only"
  tags                         = local.tags
}
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.verifier.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS bootstrap, pinned image and owned AWS API requests"
  tags              = local.tags
}
module "postgres" {
  #checkov:skip=CKV_AWS_157:This synthetic disposable module proof intentionally uses one AZ; it makes no HA claim.
  #checkov:skip=CKV_AWS_293:Protection defaults on; retire=true explicitly releases it in a separately reviewed cleanup apply.
  #checkov:skip=CKV_AWS_139:Same protection expression; Aurora count is zero in this RDS-only proof.
  #checkov:skip=CKV_AWS_353:Short disposable proof disables Performance Insights; no performance/production claim.
  #checkov:skip=CKV_AWS_129:SQL logs are not exported; avoids unmanaged log groups and logging credential-bearing synthetic role DDL.
  #checkov:skip=CKV_AWS_324:Aurora count is zero; no SQL logs are exported in this proof.
  source    = "../../modules/aws/postgres"
  providers = { aws = aws, random = random }

  name                                = "${local.name}-pg"
  engine_version                      = var.postgres_version
  database_name                       = "moduleproof"
  master_username                     = "proof_admin"
  instance_class                      = "db.t4g.micro"
  subnet_ids                          = local.private_ids
  vpc_security_group_ids              = [aws_security_group.database.id]
  multi_az                            = false
  allocated_storage                   = 20
  max_allocated_storage               = 0
  backup_retention_days               = 1
  deletion_protection                 = !var.retire
  skip_final_snapshot                 = true # Synthetic-only. Explicit TF-owned snapshot below; no orphan final snapshots.
  performance_insights_enabled        = false
  enabled_cloudwatch_logs_exports     = [] # No transcript-bearing SQL logs or unmanaged log group lifecycle.
  auto_minor_version_upgrade          = true
  iam_database_authentication_enabled = true
  allowed_extensions                  = ["pg_trgm", "vector"]
  parameters = [
    { name = "log_statement", value = "none", apply_method = "immediate" },
    { name = "log_min_error_statement", value = "panic", apply_method = "immediate" },
    { name = "log_parameter_max_length_on_error", value = "0", apply_method = "immediate" }
  ] # Do not log generated synthetic login passwords through failing DDL/parameters.
  tags       = local.tags
  depends_on = [terraform_data.guard, aws_route_table_association.private_first, aws_route_table_association.private_second]
}
module "objects" {
  source = "../../modules/aws/object-storage"

  bucket_name        = local.bucket
  force_destroy      = false
  versioning_enabled = true
  access_role        = null # EC2 trust and narrower proof identity are owned below.
  tags               = local.tags
  depends_on         = [terraform_data.guard]
}
resource "aws_s3_object" "sentinel" {
  bucket                 = module.objects.bucket_name
  key                    = "unrelated/sentinel"
  content                = "preserve-during-verifier-${local.marker}"
  server_side_encryption = "aws:kms"
  tags                   = local.tags
  depends_on             = [module.objects]
  lifecycle {
    postcondition {
      condition     = self.version_id == null ? false : length(trimspace(self.version_id)) > 0 && self.version_id != "null"
      error_message = "The sentinel must have a real immutable VersionId after versioning/encryption setup; preserve state and reconcile any partial creation."
    }
  }
}
resource "aws_db_snapshot" "marker" {
  count                  = var.restore_checkpoint == null ? 0 : 1
  db_instance_identifier = module.postgres.instance_identifier
  db_snapshot_identifier = "${local.name}-marker"
  tags                   = local.tags
}
resource "aws_db_instance" "restored" {
  #checkov:skip=CKV_AWS_293:Protection defaults on and is released only through explicit retire=true.
  #checkov:skip=CKV_AWS_353:Short disposable restore clone; no performance/production claim.
  #checkov:skip=CKV_AWS_157:Synthetic single-AZ restore proof, not an HA environment.
  #checkov:skip=CKV_AWS_129:Avoid SQL log export and unmanaged log group lifecycle in this synthetic fixture.
  #checkov:skip=CKV_AWS_133:This disposable clone is itself restored from the explicit TF-owned marker snapshot; it creates no retained automated backups.
  #checkov:skip=CKV_AWS_118:No Enhanced Monitoring role is created for the bounded synthetic clone.
  count                               = var.restore_checkpoint == null ? 0 : 1
  identifier                          = "${local.name}-restored"
  snapshot_identifier                 = aws_db_snapshot.marker[0].id
  instance_class                      = "db.t4g.micro"
  db_subnet_group_name                = module.postgres.db_subnet_group_name
  vpc_security_group_ids              = [aws_security_group.database.id]
  parameter_group_name                = "${local.name}-pg"
  publicly_accessible                 = false
  storage_encrypted                   = true
  storage_type                        = "gp3"
  multi_az                            = false
  backup_retention_period             = 0
  delete_automated_backups            = true
  deletion_protection                 = !var.retire
  skip_final_snapshot                 = true
  auto_minor_version_upgrade          = true
  iam_database_authentication_enabled = true
  copy_tags_to_snapshot               = true
  ca_cert_identifier                  = "rds-ca-rsa2048-g1"
  # PostgreSQL restore cannot enable Secrets Manager integration during restore.
  # Its inherited credential is read ONLY from the seed's exact historical
  # primary secret VersionId in guest memory. Never supply password/password_wo.
  tags = local.tags
}
