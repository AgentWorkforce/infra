data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# Private subnet: no public IPs. Egress (SSM, package repos, Neon, Supabase)
# goes through a NAT gateway in the existing public subnet.
resource "aws_subnet" "private" {
  vpc_id                  = var.vpc_id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-private" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_id
  tags          = { Name = var.name }
}

resource "aws_route_table" "private" {
  vpc_id = var.vpc_id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# No ingress at all: access is SSM Session Manager only. Egress is limited to
# HTTPS (SSM, dnf repositories), Postgres (Neon and Supabase publish no fixed
# addresses, so the destination is open) and DNS to the VPC resolver.
resource "aws_security_group" "this" {
  name        = var.name
  description = "Neon exit runner: no ingress, SSM only"
  vpc_id      = var.vpc_id
  tags        = { Name = var.name }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "SSM, Secrets Manager, package repositories"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id = aws_security_group.this.id
  description       = "Neon source and Supabase target"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "postgres_pooler" {
  security_group_id = aws_security_group.this.id
  description       = "Supabase session pooler"
  ip_protocol       = "tcp"
  from_port         = 6543
  to_port           = 6543
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.this.id
  description       = "VPC DNS resolver"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.this.id
  description       = "VPC DNS resolver"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

# The target credential: created empty. Whoever holds the Supabase owner
# password writes the value (put-secret-value); it never passes through Relay
# or this configuration.
resource "aws_secretsmanager_secret" "db_owner" {
  name                    = var.db_owner_secret_name
  description             = "Owner credential of the relayhistory-legacy target database (written out of band)"
  recovery_window_in_days = 0
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = var.name
  description        = "Neon exit runner: SSM core plus read of the one target secret"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "secret_read" {
  statement {
    sid       = "ReadTargetOwnerSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.db_owner.arn]
  }
}

resource "aws_iam_role_policy" "secret_read" {
  name   = "${var.name}-secret-read"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.secret_read.json
}

resource "aws_iam_instance_profile" "runner" {
  name = var.name
  role = aws_iam_role.runner.name
}

resource "aws_instance" "runner" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  associate_public_ip_address = false

  # user_data installs packages over the NAT path; make sure the route, the
  # association and the egress rules exist before the instance boots.
  depends_on = [
    aws_route.private_default,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.https,
    aws_vpc_security_group_egress_rule.postgres,
    aws_vpc_security_group_egress_rule.postgres_pooler,
    aws_vpc_security_group_egress_rule.dns_udp,
    aws_vpc_security_group_egress_rule.dns_tcp,
  ]
  ebs_optimized               = true
  monitoring                  = false
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    secret_name = aws_secretsmanager_secret.db_owner.name
    region      = var.region
  })

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami]
  }
}
