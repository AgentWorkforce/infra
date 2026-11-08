resource "aws_iam_role" "verifier" {
  name                 = "${local.name}-verifier"
  path                 = "/pippen/workload/"
  permissions_boundary = local.boundary
  assume_role_policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags                 = local.tags
  depends_on           = [terraform_data.guard]
}
resource "aws_iam_role_policy" "verifier" {
  name = "${local.name}-verifier"
  role = aws_iam_role.verifier.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:ListBucket", "s3:ListBucketVersions"], Resource = module.objects.bucket_arn, Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline }, StringLike = { "s3:prefix" = "${local.prefix}*" } } },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = "${module.objects.bucket_arn}/${local.prefix}*", Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline } } },
    { Effect = "Allow", Action = "s3:GetObjectVersion", Resource = "${module.objects.bucket_arn}/${local.payload}", Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline }, StringEquals = { "s3:VersionId" = coalesce(var.payload_version_id, "NOT_UPLOADED") } } },
    { Effect = "Allow", Action = "s3:GetObjectVersion", Resource = "${module.objects.bucket_arn}/receipts/seed.json", Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline }, StringEquals = { "s3:VersionId" = try(var.restore_checkpoint.seed_receipt_version_id, "NOT_SEEDED") } } },
    { Effect = "Allow", Action = "s3:PutObject", Resource = ["${module.objects.bucket_arn}/${local.receipt}", "${module.objects.bucket_arn}/receipts/${local.phase}.pending.json"], Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline } } },
    { Effect = "Deny", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], NotResource = ["${module.objects.bucket_arn}/${local.prefix}*", "${module.objects.bucket_arn}/${local.payload}", "${module.objects.bucket_arn}/${local.receipt}", "${module.objects.bucket_arn}/receipts/${local.phase}.pending.json", "${module.objects.bucket_arn}/receipts/seed.json"] },
    { Effect = "Deny", Action = ["s3:ListBucket", "s3:ListBucketVersions"], Resource = module.objects.bucket_arn, Condition = { StringNotLike = { "s3:prefix" = "${local.prefix}*" } } },
    { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "arn:aws:kms:${var.region}:${var.account_id}:key/*", Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline }, StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com", "kms:EncryptionContext:aws:s3:arn" = module.objects.bucket_arn } } },
    { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = [module.postgres.master_user_secret_arn, aws_secretsmanager_secret.runtime.arn], Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline } } },
    { Effect = "Allow", Action = "secretsmanager:PutSecretValue", Resource = aws_secretsmanager_secret.runtime.arn, Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline } } },
    { Effect = "Deny", Action = "secretsmanager:GetSecretValue", NotResource = [module.postgres.master_user_secret_arn, aws_secretsmanager_secret.runtime.arn] },
    { Effect = "Deny", Action = "secretsmanager:PutSecretValue", NotResource = aws_secretsmanager_secret.runtime.arn },
    { Effect = "Allow", Action = ["rds:DescribeDBInstances", "rds:ListTagsForResource"], Resource = [module.postgres.resource_arn, "arn:aws:rds:${var.region}:${var.account_id}:db:${local.name}-restored"], Condition = { DateLessThan = { "aws:CurrentTime" = var.deadline } } }
  ] })
}
resource "aws_iam_instance_profile" "verifier" {
  name = "eks-${local.name}-verifier"
  path = "/"
  role = aws_iam_role.verifier.name
  tags = local.tags
}
locals {
  guest = {
    account_id                = var.account_id, region = var.region, source_sha = var.source_sha, vpc_id = var.vpc_id,
    bucket                    = module.objects.bucket_name, prefix = local.prefix, payload_key = local.payload, payload_version_id = var.payload_version_id,
    payload_sha256            = var.payload_sha256, receipt_key = local.receipt, phase = local.phase,
    marker                    = local.marker, ca_sha256 = var.rds_ca_sha256, database = module.postgres.initial_database,
    host                      = var.restore_checkpoint == null ? module.postgres.host : aws_db_instance.restored[0].address,
    instance_id               = var.restore_checkpoint == null ? module.postgres.instance_identifier : aws_db_instance.restored[0].identifier,
    source_instance_id        = module.postgres.instance_identifier,
    secret_arn                = module.postgres.master_user_secret_arn,
    secret_version_id         = try(var.restore_checkpoint.secret_version_id, null),
    seed_receipt_sha256       = try(var.restore_checkpoint.seed_receipt_sha256, null),
    seed_receipt_version_id   = try(var.restore_checkpoint.seed_receipt_version_id, null),
    provider_lock_sha256      = filesha256("${path.module}/.terraform.lock.hcl")
    node_image                = "node@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57"
    psql_image                = "postgres@sha256:748a18a54d3842d43bc156f0840d78029b8d349e0feca98c12b9c4ce3404a6b3"
    deadline                  = var.deadline
    postgres_version          = var.postgres_version
    verifier_role_arn         = aws_iam_role.verifier.arn
    expected_tags             = local.tags
    guest_sources             = var.guest_sources
    runtime_secret_arn        = aws_secretsmanager_secret.runtime.arn
    runtime_secret_version_id = try(var.restore_checkpoint.runtime_secret_version_id, null)
    seed_evidence_sha256      = try(var.restore_checkpoint.seed_evidence_sha256, null)
    # Provisioning executor (RDS master) is distinct from the application owner/runtime.
    provisioning_executor  = module.postgres.master_username
    forbidden_roles        = [module.postgres.master_username]
    application            = local.application
    application_activation = var.application_activation
    pending_receipt_key    = "receipts/${local.phase}.pending.json"
  }
  bootstrap = templatefile("${path.module}/bootstrap.sh.tftpl", { config = jsonencode(local.guest), extractor = file("${path.module}/proof/extract_payload.py") })
}
resource "aws_launch_template" "verifier" {
  #checkov:skip=CKV_AWS_88:Disposable no-ingress host needs HTTPS egress through the existing reviewed IGW subnet. No key or inbound service exists.
  name          = "${local.name}-verifier"
  image_id      = var.ami_id
  instance_type = "m7g.large"
  user_data     = base64encode(local.bootstrap)
  iam_instance_profile { name = aws_iam_instance_profile.verifier.name }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
  network_interfaces {
    device_index                = 0
    subnet_id                   = var.host_subnet_id
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.verifier.id]
  }
  block_device_mappings {
    device_name = data.aws_ami.host.root_device_name
    ebs {
      encrypted             = true
      delete_on_termination = true
      volume_type           = "gp3"
      volume_size           = 20
    }
  }
  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.key
      tags          = local.tags
    }
  }
  tags = local.tags
  lifecycle {
    precondition {
      condition     = length(local.bootstrap) <= 16384
      error_message = "Bootstrap exceeds EC2 user-data limit."
    }
  }
}
resource "aws_instance" "verifier" {
  #checkov:skip=CKV2_AWS_41:Role/profile is explicitly supplied in the referenced launch template; the mock asserts that exact binding.
  count = var.retire || var.payload_version_id == null ? 0 : 1
  #checkov:skip=CKV_AWS_79:IMDSv2 required/hop1 is explicit in the referenced owned launch template and asserted in mock tests.
  #checkov:skip=CKV_AWS_8:Encrypted gp3/delete-on-termination is explicit in the referenced launch template and asserted in mock tests.
  lifecycle { replace_triggered_by = [terraform_data.execution] }
  launch_template {
    id      = aws_launch_template.verifier.id
    version = aws_launch_template.verifier.latest_version
  }
  instance_initiated_shutdown_behavior = "terminate"
  disable_api_termination              = false
  ebs_optimized                        = true
  monitoring                           = true
  tags                                 = local.tags
  depends_on                           = [terraform_data.application_gate, aws_iam_role_policy.verifier, aws_vpc_security_group_ingress_rule.database, aws_vpc_security_group_egress_rule.database, aws_vpc_security_group_egress_rule.https]
}

resource "terraform_data" "execution" {
  input = { phase = local.phase, checkpoint = var.restore_checkpoint, payload_version_id = var.payload_version_id }
}
