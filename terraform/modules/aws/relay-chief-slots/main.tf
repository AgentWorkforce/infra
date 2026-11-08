data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_ssm_parameter" "ami" {
  count = var.ami_ssm_parameter == null ? 0 : 1

  name = var.ami_ssm_parameter
}

locals {
  ami_id     = var.ami_ssm_parameter == null ? var.ami_id : data.aws_ssm_parameter.ami[0].insecure_value
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # An s3:// URI maps directly onto the object ARN, so the grant is that object
  # alone. Validation keeps IAM wildcards out of the key.
  artifact_url        = try(var.relay_chief_artifact.url, "")
  artifact_object_arn = startswith(local.artifact_url, "s3://") ? "arn:${local.partition}:s3:::${trimprefix(local.artifact_url, "s3://")}" : null

  # Secret names are <prefix>/<slot id>. "-??????" is the random suffix Secrets
  # Manager appends, so the pattern matches only this slot's secret: a longer
  # name that starts with the same slot id has more than six trailing characters.
  slots = {
    for id in var.slot_ids : id => {
      secret_name        = "${var.secret_name_prefix}/${id}"
      secret_arn_pattern = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${var.secret_name_prefix}/${id}-??????"
      name               = "${var.name_prefix}-${id}"
    }
  }

  # Every file bootstrap installs, shipped base64 encoded so that shell and
  # systemd syntax never meets templatefile interpolation. relay-chief.service
  # and relay-chief.timer are unmodified copies of the relay-chief deploy/ units.
  host_files = [
    { path = "/etc/systemd/system/relay-chief.service", mode = "0644", content = filebase64("${path.module}/files/relay-chief.service") },
    { path = "/etc/systemd/system/relay-chief.timer", mode = "0644", content = filebase64("${path.module}/files/relay-chief.timer") },
    { path = "/etc/systemd/system/relay-chief.service.d/10-slot.conf", mode = "0644", content = filebase64("${path.module}/files/10-slot.conf") },
    { path = "/etc/systemd/system/relay-chief-credentials.service", mode = "0644", content = filebase64("${path.module}/files/relay-chief-credentials.service") },
    { path = "/usr/local/sbin/relay-chief-fetch-credentials", mode = "0755", content = filebase64("${path.module}/files/fetch-credentials.sh") },
    { path = "/usr/local/sbin/relay-chief-bind-slot", mode = "0755", content = filebase64("${path.module}/files/bind-slot.sh") },
    { path = "/usr/local/sbin/relay-chief-fetch-artifact", mode = "0755", content = filebase64("${path.module}/files/fetch-artifact.sh") },
    { path = "/usr/local/sbin/relay-chief-prepare-data-volume", mode = "0755", content = filebase64("${path.module}/files/prepare-data-volume.sh") },
  ]

  # Rendered per slot. Holds identifiers and checksums only, never a credential.
  bootstrap = {
    for id, slot in local.slots : id => templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
      slot_id     = id
      secret_name = slot.secret_name
      region      = local.region
      # Opaque to the runtime, which only checks its format. Infra owns the mapping.
      placement  = local.region
      size_class = split(".", var.instance_type)[1]
      # On Nitro instances the attached volume appears under its id, so a host
      # can only ever mount the volume created for its own slot.
      data_device     = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data[id].id, "-", "")}"
      node_url        = var.node_runtime.url
      node_sha256     = var.node_runtime.sha256
      artifact_url    = local.artifact_url
      artifact_sha256 = try(var.relay_chief_artifact.sha256, "")
      files           = local.host_files
    })
  }
}

resource "aws_security_group" "slots" {
  name        = "${var.name_prefix}-slots"
  description = "Relay Chief slots: no inbound, outbound HTTPS only"
  vpc_id      = var.vpc_id
  tags        = var.tags

  # Declared empty on purpose: this makes the module authoritative, so a rule
  # added out of band is removed by the next apply. Operators connect through SSM.
  ingress = []

  egress {
    description = "HTTPS to AWS APIs, Relay, classification and the control plane"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.egress_cidr_blocks
  }
}

resource "aws_iam_role" "slot" {
  for_each = local.slots

  name                 = each.value.name
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary_arn
  tags                 = merge(var.tags, { "relay:chief-slot" = each.key })

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.${local.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "slot_secret" {
  for_each = local.slots

  name = "read-slot-secret"
  role = aws_iam_role.slot[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSlotSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [each.value.secret_arn_pattern]
      },
      {
        # The key is shared between slots. The encryption context Secrets
        # Manager supplies is what limits this role to its own slot's secret.
        Sid      = "DecryptSlotSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.${local.dns_suffix}" }
          StringLike   = { "kms:EncryptionContext:SecretARN" = each.value.secret_arn_pattern }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "artifact" {
  for_each = local.artifact_object_arn == null ? {} : local.slots

  name = "read-relay-chief-artifact"
  role = aws_iam_role.slot[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadRelayChiefArtifact"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = [local.artifact_object_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = local.slots

  role       = aws_iam_role.slot[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "slot" {
  for_each = local.slots

  name = each.value.name
  path = var.iam_path
  role = aws_iam_role.slot[each.key].name
  tags = merge(var.tags, { "relay:chief-slot" = each.key })
}

# The chief ledger lives here, outside the instance lifecycle. A slot's ledger
# is its dispatch record, so losing it risks duplicate customer assignments:
# destroying a volume needs an explicit change to this module.
resource "aws_ebs_volume" "data" {
  for_each = local.slots

  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.kms_key_arn
  tags              = merge(var.tags, { "relay:chief-slot" = each.key, "relay:service" = "relay-chief" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "slot" {
  for_each = local.slots

  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.slots.id]
  iam_instance_profile        = aws_iam_instance_profile.slot[each.key].name
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true
  user_data_base64            = base64gzip(local.bootstrap[each.key])
  tags                        = merge(var.tags, { "relay:chief-slot" = each.key, "relay:service" = "relay-chief" })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
  }

  lifecycle {
    # Replacing a host stops its chief and reattaches its ledger, so it is
    # always a deliberate -replace, never a side effect of a new AMI or template.
    ignore_changes = [ami, user_data_base64]

    precondition {
      condition     = (var.ami_id == null) != (var.ami_ssm_parameter == null)
      error_message = "Set exactly one of ami_id and ami_ssm_parameter."
    }
  }
}

resource "aws_volume_attachment" "data" {
  for_each = local.slots

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[each.key].id
  instance_id = aws_instance.slot[each.key].id

  # Replacement detaches a live SQLite ledger otherwise.
  stop_instance_before_detaching = true
}
