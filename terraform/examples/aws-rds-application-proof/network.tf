# Existing VPC and all existing routes remain external. This optional mode owns
# only two subnets, one local-only route table and its two explicit associations.
data "aws_vpc" "existing" {
  count = var.create_private_subnets == null ? 0 : 1
  id    = var.vpc_id
}
data "aws_availability_zones" "available" {
  count = var.create_private_subnets == null ? 0 : 1
  state = "available"
  filter {
    name   = "zone-name"
    values = [for subnet in values(var.create_private_subnets) : subnet.az]
  }
}
data "aws_subnets" "inventory" {
  count = var.create_private_subnets == null ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}
data "aws_subnet" "inventory" {
  for_each = var.create_private_subnets == null ? toset([]) : toset(data.aws_subnets.inventory[0].ids)
  id       = each.value
}
locals {
  new_subnets = var.create_private_subnets == null ? {} : var.create_private_subnets
  new_ranges = { for slot, subnet in local.new_subnets : slot => {
    start = try(sum([for i, octet in split(".", cidrhost(subnet.cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]), -1)
    end   = try(sum([for i, octet in split(".", cidrhost(subnet.cidr, -1)) : tonumber(octet) * pow(256, 3 - i)]), -1)
  } }
  vpc_range = var.create_private_subnets == null ? null : {
    start = sum([for i, octet in split(".", cidrhost(data.aws_vpc.existing[0].cidr_block, 0)) : tonumber(octet) * pow(256, 3 - i)])
    end   = sum([for i, octet in split(".", cidrhost(data.aws_vpc.existing[0].cidr_block, -1)) : tonumber(octet) * pow(256, 3 - i)])
  }
  # Subsequent plans see our own subnets too. Exempt only an exact slot/CIDR/AZ
  # with the current lease/run ownership tags. This never imports/adopts a subnet;
  # AWS CreateSubnet still refuses an overlap if an owned-looking orphan exists.
  foreign_ranges = [for subnet in data.aws_subnet.inventory : {
    start = sum([for i, octet in split(".", cidrhost(subnet.cidr_block, 0)) : tonumber(octet) * pow(256, 3 - i)])
    end   = sum([for i, octet in split(".", cidrhost(subnet.cidr_block, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } if !anytrue([for slot, spec in local.new_subnets : subnet.owner_id == var.account_id && subnet.cidr_block == spec.cidr && subnet.availability_zone == spec.az && !subnet.map_public_ip_on_launch && try(subnet.tags.Name, "") == "${local.name}-private-${slot}" && alltrue([for key, value in local.tags : try(subnet.tags[key], "") == value])])]
}
resource "terraform_data" "network_guard" {
  input = var.create_private_subnets
  lifecycle {
    precondition {
      condition     = var.create_private_subnets == null ? true : data.aws_vpc.existing[0].owner_id == var.account_id && data.aws_vpc.existing[0].default
      error_message = "Owned subnet mode is bounded to the reviewed existing default VPC in the expected account."
    }
    precondition {
      condition     = var.create_private_subnets == null ? true : length(toset([for subnet in values(local.new_subnets) : subnet.az])) == 2 && alltrue([for subnet in values(local.new_subnets) : contains(data.aws_availability_zones.available[0].names, subnet.az)])
      error_message = "Require two distinct available AZs in the selected region."
    }
    precondition {
      condition     = var.create_private_subnets == null ? true : alltrue([for range in values(local.new_ranges) : range.start >= local.vpc_range.start && range.end <= local.vpc_range.end]) && (local.new_ranges.first.end < local.new_ranges.second.start || local.new_ranges.second.end < local.new_ranges.first.start)
      error_message = "Owned subnet CIDRs must fit the VPC primary IPv4 CIDR and must not overlap each other."
    }
    precondition {
      condition     = alltrue(flatten([for range in values(local.new_ranges) : [for existing in local.foreign_ranges : range.end < existing.start || existing.end < range.start]]))
      error_message = "Owned subnet CIDRs overlap existing foreign subnet inventory; review fresh read-only metadata."
    }
  }
  depends_on = [terraform_data.guard]
}
resource "aws_subnet" "private_first" {
  count                   = var.create_private_subnets == null ? 0 : 1
  vpc_id                  = var.vpc_id
  cidr_block              = var.create_private_subnets.first.cidr
  availability_zone       = var.create_private_subnets.first.az
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.name}-private-first" })
  depends_on              = [terraform_data.network_guard]
}
resource "aws_subnet" "private_second" {
  count                   = var.create_private_subnets == null ? 0 : 1
  vpc_id                  = var.vpc_id
  cidr_block              = var.create_private_subnets.second.cidr
  availability_zone       = var.create_private_subnets.second.az
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.name}-private-second" })
  depends_on              = [terraform_data.network_guard]
}
resource "aws_route_table" "private" {
  count            = var.create_private_subnets == null ? 0 : 1
  vpc_id           = var.vpc_id
  route            = []
  propagating_vgws = []
  tags             = merge(local.tags, { Name = "${local.name}-private" })
  depends_on       = [terraform_data.network_guard]
}
resource "aws_route_table_association" "private_first" {
  count          = var.create_private_subnets == null ? 0 : 1
  subnet_id      = aws_subnet.private_first[0].id
  route_table_id = aws_route_table.private[0].id
}
resource "aws_route_table_association" "private_second" {
  count          = var.create_private_subnets == null ? 0 : 1
  subnet_id      = aws_subnet.private_second[0].id
  route_table_id = aws_route_table.private[0].id
}
