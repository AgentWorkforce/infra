resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
  depends_on           = [terraform_data.guard]
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  # Revoke AWS default allow-all rules. Application groups below are explicit.
  tags = merge(local.tags, { Name = "${local.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = local.tags
}
resource "aws_subnet" "public" {
  for_each                = var.subnets
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.public_cidr
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.name}-public-${each.key}", "kubernetes.io/role/elb" = "1" })
}
resource "aws_subnet" "private" {
  for_each                = var.subnets
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.private_cidr
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.name}-private-${each.key}", "kubernetes.io/role/internal-elb" = "1" })
}
resource "aws_eip" "nat" {
  for_each = var.subnets
  domain   = "vpc"
  tags     = local.tags
}
resource "aws_nat_gateway" "this" {
  for_each          = var.subnets
  allocation_id     = aws_eip.nat[each.key].id
  subnet_id         = aws_subnet.public[each.key].id
  connectivity_type = "public"
  tags              = local.tags
  depends_on        = [aws_internet_gateway.this]
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = local.tags
}
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}
resource "aws_route_table_association" "public" {
  for_each       = var.subnets
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "private" {
  for_each = var.subnets
  vpc_id   = aws_vpc.this.id
  tags     = local.tags
}
resource "aws_route" "nat" {
  for_each               = var.subnets
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
}
resource "aws_route_table_association" "private" {
  for_each       = var.subnets
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_security_group" "this" {
  #checkov:skip=CKV2_AWS_5:Database/search/function groups are exported to separate data state; this foundation root deliberately has no RDS/domain/Lambda attachment. Verify those bindings in the data plan and live proof.
  for_each    = toset(["workload", "database", "search", "function", "operator-api", "eks-auth"])
  name        = "${local.name}-${each.key}"
  description = "Environment ${var.environment} ${each.key} traffic"
  vpc_id      = aws_vpc.this.id
  tags        = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "database" {
  for_each                     = toset(["workload", "function"])
  security_group_id            = aws_security_group.this["database"].id
  referenced_security_group_id = aws_security_group.this[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from environment ${each.key}"
}
resource "aws_vpc_security_group_ingress_rule" "search" {
  for_each                     = toset(["workload", "function"])
  security_group_id            = aws_security_group.this["search"].id
  referenced_security_group_id = aws_security_group.this[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "OpenSearch HTTPS from environment ${each.key}"
}
resource "aws_vpc_security_group_egress_rule" "https" {
  for_each          = toset(["workload", "function"])
  security_group_id = aws_security_group.this[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Reviewed NAT egress for AWS APIs, artifact registries and HTTPS origins"
}
resource "aws_vpc_security_group_egress_rule" "database" {
  for_each                     = toset(["workload", "function"])
  security_group_id            = aws_security_group.this[each.key].id
  referenced_security_group_id = aws_security_group.this["database"].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Environment PostgreSQL"
}
resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each          = { for pair in setproduct(["workload", "function"], ["tcp", "udp"]) : "${pair[0]}-${pair[1]}" => pair }
  security_group_id = aws_security_group.this[each.value[0]].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = each.value[1]
  from_port         = 53
  to_port           = 53
  description       = "Private DNS"
}
resource "aws_vpc_security_group_ingress_rule" "operator_cidr" {
  for_each          = toset(var.operator_cidrs)
  security_group_id = aws_security_group.this["operator-api"].id
  cidr_ipv4         = each.key
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Approved operator API network"
}
resource "aws_vpc_security_group_ingress_rule" "operator_sg" {
  for_each                     = var.operator_security_group_ids
  security_group_id            = aws_security_group.this["operator-api"].id
  referenced_security_group_id = each.key
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Approved operator API runner"
}
resource "aws_vpc_security_group_ingress_rule" "eks_auth" {
  security_group_id            = aws_security_group.this["eks-auth"].id
  referenced_security_group_id = aws_security_group.this["workload"].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Node Pod Identity agent to EKS Auth PrivateLink"
}
resource "aws_vpc_endpoint" "eks_auth" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.eks-auth"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [for az in local.azs : aws_subnet.private[az].id]
  security_group_ids  = [aws_security_group.this["eks-auth"].id]
  tags                = local.tags
}
