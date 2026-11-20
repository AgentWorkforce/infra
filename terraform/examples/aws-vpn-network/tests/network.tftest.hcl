mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_vpc" { defaults = { cidr_block = "10.60.0.0/16", owner_id = "123456789012" } }
  mock_data "aws_subnet" { defaults = { cidr_block = "10.60.1.0/24", vpc_id = "vpc-1234567890abcdef0", availability_zone = "us-east-1a", owner_id = "123456789012" } }
  mock_resource "aws_eip" { defaults = { public_ip = "203.0.113.10" } }
}
variables {
  region               = "us-east-1"
  enabled              = true
  account_id           = "123456789012"
  vpc_id               = "vpc-1234567890abcdef0"
  availability_zone    = "us-east-1a"
  nat_public_subnet_id = "subnet-1234567890abcdef0"
  connector_cidr       = "10.60.0.0/28"
  outbound_rules       = { vpn = { cidr = "203.0.113.9/32", protocol = "udp", port = 1194 } }
}
run "disabled_example" {
  command = plan
  variables { enabled = false }
  assert {
    condition     = output.vpn_network.egress_cidr == null && output.vpn_network.connector_subnet_id == null
    error_message = "The standalone root must preserve the module's disabled outputs."
  }
}
run "enabled_example" {
  command = apply
  assert {
    condition     = output.vpn_network.egress_cidr == "203.0.113.10/32" && output.vpn_network.connector_subnet_id != null
    error_message = "Opt-in must propagate through the standalone root and expose connector placement and static egress."
  }
}
