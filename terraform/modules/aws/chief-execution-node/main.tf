data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_ssm_parameter" "ami" {
  count = var.ami_id == null ? 1 : 0

  name = var.ami_ssm_parameter
}

locals {
  ami_id     = var.ami_id == null ? data.aws_ssm_parameter.ami[0].insecure_value : var.ami_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  region     = data.aws_region.current.region

  # Shipped base64 encoded so that shell and systemd syntax never meets
  # templatefile interpolation.
  host_files = [
    { path = "/etc/systemd/system/chief-node-metadata-block.service", mode = "0644", content = filebase64("${path.module}/files/chief-node-metadata-block.service") },
    { path = "/etc/systemd/system/chief-node.service", mode = "0644", content = filebase64("${path.module}/files/chief-node.service") },
    { path = "/etc/systemd/system/chief-bridge.service", mode = "0644", content = filebase64("${path.module}/files/chief-bridge.service") },
    { path = "/usr/local/sbin/chief-bridge-fetch-token", mode = "0700", content = filebase64("${path.module}/files/fetch-bridge-token.sh") },
    { path = "/usr/local/sbin/chief-node-apply-settings", mode = "0700", content = filebase64("${path.module}/files/apply-node-settings.sh") },
    { path = "/usr/local/sbin/chief-node-fetch-harness-key", mode = "0700", content = filebase64("${path.module}/files/fetch-harness-key.sh") },
  ]

  bootstrap = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    node_runtime   = var.node_runtime
    relay_node     = var.relay_node
    harness        = var.harness
    bridge         = var.bridge
    relay_base_url = var.relay_base_url
    region         = local.region
    secret_arn     = aws_secretsmanager_secret.worker_token.arn

    harness_key_secret_arn = aws_secretsmanager_secret.harness_key.arn
    repositories           = var.repositories
    files                  = local.host_files
  })
}

resource "aws_secretsmanager_secret" "worker_token" {
  #checkov:skip=CKV2_AWS_57:The value is issued by Relay and copied in out of band; there is no rotation function to attach.
  name                    = "${var.name}/worker-token"
  description             = "Relay token for the Chief execution bridge. Read at service start by a root-run step only."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret" "harness_key" {
  #checkov:skip=CKV2_AWS_57:The value is issued by the harness provider and copied in out of band; there is no rotation function to attach.
  name                    = "${var.name}/harness-api-key"
  description             = "API key for spawned harnesses. Read at node start by a root-run step only."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "Chief execution node: no inbound, outbound HTTPS only"
  vpc_id      = data.aws_subnet.this.vpc_id
  tags        = var.tags

  # Declared empty on purpose: a rule added out of band is removed by the next
  # apply. Operators connect through SSM.
  ingress = []

  egress {
    description = "HTTPS to AWS APIs, Relay, GitHub, npm and the harness provider"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.egress_cidr_blocks
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  path                 = var.iam_path
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.${local.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "worker_token" {
  name = "read-node-secrets"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadNodeSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.worker_token.arn, aws_secretsmanager_secret.harness_key.arn]
      },
      {
        # The key is shared. The encryption context Secrets Manager supplies is
        # what limits this role to these two secrets.
        Sid      = "DecryptNodeSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${local.region}.${local.dns_suffix}"
            "kms:EncryptionContext:SecretARN" = [aws_secretsmanager_secret.worker_token.arn, aws_secretsmanager_secret.harness_key.arn]
          }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = var.name
  path = var.iam_path
  role = aws_iam_role.this.name
  tags = var.tags
}

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true
  user_data_base64            = base64gzip(local.bootstrap)
  tags                        = merge(var.tags, { Name = var.name, "relay:service" = "chief-execution-node" })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_protocol_ipv6          = "disabled"
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
  }

  depends_on = [aws_iam_role_policy_attachment.ssm, aws_iam_role_policy.worker_token]

  lifecycle {
    # The host holds a ledger and a human's harness login, so replacing it is
    # always a deliberate -replace, never a side effect of a new AMI or template.
    ignore_changes = [ami, user_data_base64]

    precondition {
      condition     = !data.aws_subnet.this.map_public_ip_on_launch
      error_message = "The execution node must be in a private subnet."
    }
  }
}
