mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_vpc" { defaults = { cidr_block = "10.60.0.0/16", owner_id = "123456789012" } }
  mock_data "aws_subnet" { defaults = { cidr_block = "10.60.1.0/24", vpc_id = "vpc-1234567890abcdef0", availability_zone = "us-east-1a", owner_id = "123456789012" } }
  mock_resource "aws_eip" { defaults = { public_ip = "203.0.113.10" } }
}
variables {
  enabled              = true
  account_id           = "123456789012"
  vpc_id               = "vpc-1234567890abcdef0"
  availability_zone    = "us-east-1a"
  nat_public_subnet_id = "subnet-1234567890abcdef0"
  connector_cidr       = "10.60.0.0/28"
  outbound_rules       = { vpn = { cidr = "203.0.113.9/32", protocol = "udp", port = 1194 } }
}
run "default_off" {
  command = plan
  variables { enabled = false }
  assert {
    condition     = length(aws_subnet.connector) == 0 && length(aws_eip.egress) == 0 && length(aws_nat_gateway.this) == 0 && length(aws_route_table.connector) == 0 && length(aws_route.egress) == 0 && length(aws_route_table_association.connector) == 0 && length(aws_security_group.connector) == 0 && length(aws_vpc_security_group_egress_rule.connector) == 0 && length(data.aws_caller_identity.this) == 0 && length(data.aws_vpc.this) == 0 && length(data.aws_subnet.nat) == 0 && output.egress_cidr == null
    error_message = "Disabled must create nothing and perform no cloud data reads."
  }
}
run "private_connector_static_nat" {
  command = apply
  assert {
    condition     = !aws_subnet.connector[0].map_public_ip_on_launch && aws_nat_gateway.this[0].subnet_id == var.nat_public_subnet_id && aws_nat_gateway.this[0].allocation_id == aws_eip.egress[0].id && aws_route.egress[0].nat_gateway_id == aws_nat_gateway.this[0].id && aws_route_table_association.connector[0].subnet_id == aws_subnet.connector[0].id && output.egress_cidr == "203.0.113.10/32"
    error_message = "Connector must remain private, with a dedicated route table and stable NAT in the existing public subnet."
  }
  assert {
    condition     = length(aws_security_group.connector[0].ingress) == 0 && length(aws_security_group.connector[0].egress) == 0 && aws_vpc_security_group_egress_rule.connector["vpn"].cidr_ipv4 == "203.0.113.9/32" && aws_vpc_security_group_egress_rule.connector["vpn"].from_port == 1194 && aws_vpc_security_group_egress_rule.connector["vpn"].to_port == 1194
    error_message = "No implicit inbound/allow-all outbound rules; approve only the explicit VPN destination and port."
  }
}
run "wrong_account_refused" {
  command = plan
  variables { account_id = "999999999999" }
  expect_failures = [terraform_data.guard]
}
run "nat_az_mismatch_refused" {
  command = plan
  variables { availability_zone = "us-east-1b" }
  expect_failures = [terraform_data.guard]
}
run "nat_overlap_refused" {
  command = plan
  variables { connector_cidr = "10.60.1.0/28" }
  expect_failures = [terraform_data.guard]
}

run "routed_range_overlap_refused" {
  command = plan
  variables { existing_network_cidrs = ["10.60.0.0/24"] }
  expect_failures = [terraform_data.guard]
}
run "public_connector_refused" {
  command = plan
  variables { connector_cidr = "198.51.100.0/28" }
  expect_failures = [terraform_data.guard]
}
run "invalid_vpn_port_refused" {
  command = plan
  variables { outbound_rules = { bad = { cidr = "203.0.113.9/32", protocol = "udp", port = 0 } } }
  expect_failures = [var.outbound_rules]
}
