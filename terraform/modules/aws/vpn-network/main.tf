locals {
  # Compare whole intervals, not just network addresses, including nested ranges.
  ranges = { for key, cidr in merge({ connector = var.connector_cidr }, {
    for i, cidr in var.existing_network_cidrs : "existing-${i}" => cidr
    }) : key => {
    first = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
    last  = sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } }
  private_ranges = [
    { first = 167772160, last = 184549375 },
    { first = 2886729728, last = 2887778303 },
    { first = 3232235520, last = 3232301055 }
  ]
  private_connector = anytrue([for r in local.private_ranges : local.ranges.connector.first >= r.first && local.ranges.connector.last <= r.last])
  no_overlap = alltrue([for key, r in local.ranges : key == "connector" ||
    local.ranges.connector.last < r.first || local.ranges.connector.first > r.last
  ])
}

data "aws_caller_identity" "this" { count = var.enabled ? 1 : 0 }
data "aws_vpc" "this" {
  count = var.enabled ? 1 : 0
  id    = var.vpc_id
}
data "aws_subnet" "nat" {
  count = var.enabled ? 1 : 0
  id    = var.nat_public_subnet_id
}
locals {
  tags = merge(var.tags, { managed-by = "terraform", Name = "${var.name}-vpn" })
  vpc = var.enabled ? {
    first = sum([for i, octet in split(".", cidrhost(data.aws_vpc.this[0].cidr_block, 0)) : tonumber(octet) * pow(256, 3 - i)])
    last  = sum([for i, octet in split(".", cidrhost(data.aws_vpc.this[0].cidr_block, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } : null
  nat = var.enabled ? {
    first = sum([for i, octet in split(".", cidrhost(data.aws_subnet.nat[0].cidr_block, 0)) : tonumber(octet) * pow(256, 3 - i)])
    last  = sum([for i, octet in split(".", cidrhost(data.aws_subnet.nat[0].cidr_block, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } : null
}
resource "terraform_data" "guard" {
  count = var.enabled ? 1 : 0
  input = var.connector_cidr
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.this[0].account_id == var.account_id && data.aws_vpc.this[0].owner_id == var.account_id && data.aws_subnet.nat[0].owner_id == var.account_id
      error_message = "Caller, VPC and NAT subnet must belong to the independently approved account."
    }
    precondition {
      condition     = data.aws_subnet.nat[0].vpc_id == var.vpc_id && data.aws_subnet.nat[0].availability_zone == var.availability_zone
      error_message = "NAT subnet must be in the connector's VPC and AZ."
    }
    precondition {
      condition = local.private_connector && local.no_overlap && local.ranges.connector.first >= local.vpc.first && local.ranges.connector.last <= local.vpc.last && (
        local.ranges.connector.last < local.nat.first || local.ranges.connector.first > local.nat.last
      )
      error_message = "Connector must be unused RFC1918 space in the VPC's primary CIDR, disjoint from the NAT subnet and all supplied routed ranges."
    }
  }
}
resource "aws_subnet" "connector" {
  count                   = var.enabled ? 1 : 0
  vpc_id                  = var.vpc_id
  availability_zone       = var.availability_zone
  cidr_block              = var.connector_cidr
  map_public_ip_on_launch = false
  tags                    = local.tags
  depends_on              = [terraform_data.guard]
}
resource "aws_eip" "egress" {
  count      = var.enabled ? 1 : 0
  domain     = "vpc"
  tags       = local.tags
  depends_on = [terraform_data.guard]
}
resource "aws_nat_gateway" "this" {
  count             = var.enabled ? 1 : 0
  allocation_id     = aws_eip.egress[0].id
  subnet_id         = var.nat_public_subnet_id
  connectivity_type = "public"
  tags              = local.tags
}
resource "aws_route_table" "connector" {
  count      = var.enabled ? 1 : 0
  vpc_id     = var.vpc_id
  tags       = local.tags
  depends_on = [terraform_data.guard]
}
resource "aws_route" "egress" {
  count                  = var.enabled ? 1 : 0
  route_table_id         = aws_route_table.connector[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}
resource "aws_route_table_association" "connector" {
  count          = var.enabled ? 1 : 0
  subnet_id      = aws_subnet.connector[0].id
  route_table_id = aws_route_table.connector[0].id
}
resource "aws_security_group" "connector" {
  #checkov:skip=CKV2_AWS_5:The operator attaches this exported group to a separately owned VPN connector VM; this network module creates no instances.
  count       = var.enabled ? 1 : 0
  name_prefix = "${var.name}-vpn-"
  description = "Outbound-initiated VPN connector; no inbound rules or public SSH"
  vpc_id      = var.vpc_id
  tags        = local.tags
  depends_on  = [terraform_data.guard]
}
resource "aws_vpc_security_group_egress_rule" "connector" {
  for_each          = var.enabled ? var.outbound_rules : {}
  security_group_id = aws_security_group.connector[0].id
  description       = "Approved connector outbound: ${each.key}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  tags              = local.tags
}
