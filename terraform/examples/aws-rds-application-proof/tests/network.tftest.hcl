mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-00000000-0000-4000-8000-000000000000" } }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_data "aws_ami" { defaults = { architecture = "arm64", root_device_type = "ebs", virtualization_type = "hvm", name = "al2023-ami-example", root_device_name = "/dev/xvda" } }
  mock_data "aws_vpc" { defaults = { owner_id = "111111111111", default = true, cidr_block = "10.0.0.0/16" } }
  mock_data "aws_availability_zones" { defaults = { names = ["us-west-2a", "us-west-2b"] } }
  mock_data "aws_subnets" { defaults = { ids = [] } }
  mock_data "aws_subnet" { defaults = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2a", map_public_ip_on_launch = false, cidr_block = "10.0.240.0/24", tags = {} } }
  mock_resource "aws_launch_template" { defaults = { id = "lt-0123456789abcdef0", latest_version = 1 } }
  mock_resource "aws_security_group" { defaults = { id = "sg-0123456789abcdef0" } }
  mock_resource "aws_db_instance" { defaults = { address = "synthetic.example", arn = "arn:aws:rds:us-west-2:111111111111:db:pippen-sbx-example-pg", master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds-example", secret_status = "active", kms_key_id = "example" }] } }
  mock_resource "aws_s3_bucket" { defaults = { arn = "arn:aws:s3:::pippen-sbx-example-111111111111-us-west-2", id = "pippen-sbx-example-111111111111-us-west-2" } }
}
mock_provider "random" {}
override_resource {
  target = aws_subnet.private_first
  values = { id = "subnet-aaaaaaaaaaaaaaaaa" }
}
override_resource {
  target = aws_subnet.private_second
  values = { id = "subnet-bbbbbbbbbbbbbbbbb" }
}
override_resource {
  target = aws_security_group.verifier
  values = { id = "sg-11111111111111111" }
}
variables {
  deadline               = "2099-01-01T00:00:00.000Z"
  guest_sources          = { composition_commit = "292359f0c68b1e4615704fd51d303b7f6b4db445", manifest_sha256 = "3333333333333333333333333333333333333333333333333333333333333333", generation = "7d64ae1f74670530fd6443fad7d6cc9ac11776055941821ef79f8501fb2d7879" }
  account_id             = "111111111111"
  region                 = "us-west-2"
  run_id                 = "example"
  pippen                 = { agent = "example-agent", session_id = "00000000-0000-4000-8000-000000000000" }
  vpc_id                 = "vpc-example"
  create_private_subnets = { first = { cidr = "10.0.240.0/24", az = "us-west-2a" }, second = { cidr = "10.0.241.0/24", az = "us-west-2b" } }
  host_subnet_id         = "subnet-example-host"
  ami_id                 = "ami-example"
  postgres_version       = "17.5"
  source_sha             = "0000000000000000000000000000000000000000"
  payload_sha256         = "0000000000000000000000000000000000000000000000000000000000000000"
  rds_ca_sha256          = "0000000000000000000000000000000000000000000000000000000000000000"
}
run "owned_network_is_two_private_subnets_and_local_only_table" {
  command = apply
  assert {
    condition     = length(aws_subnet.private_first) == 1 && length(aws_subnet.private_second) == 1 && !aws_subnet.private_first[0].map_public_ip_on_launch && !aws_subnet.private_second[0].map_public_ip_on_launch && aws_subnet.private_first[0].availability_zone != aws_subnet.private_second[0].availability_zone && aws_subnet.private_first[0].tags["pippen:session"] == var.pippen.session_id
    error_message = "Own exactly two private, lease-tagged distinct AZ subnets."
  }
  assert {
    condition     = length(aws_route_table.private) == 1 && length(aws_route_table.private[0].route) == 0 && length(aws_route_table.private[0].propagating_vgws) == 0 && aws_route_table_association.private_first[0].subnet_id == aws_subnet.private_first[0].id && aws_route_table_association.private_second[0].subnet_id == aws_subnet.private_second[0].id && aws_route_table_association.private_first[0].route_table_id == aws_route_table.private[0].id && aws_route_table_association.private_second[0].route_table_id == aws_route_table.private[0].id
    error_message = "Associate only the owned subnets with one local-only table; no NAT, IGW or inherited main table."
  }
  assert {
    condition     = toset(output.proof_contract.private_subnet_ids) == toset([aws_subnet.private_first[0].id, aws_subnet.private_second[0].id]) && output.proof_contract.owned_network.route_table_id == aws_route_table.private[0].id && length(output.proof_contract.owned_network.route_association_ids) == 2
    error_message = "Expose the exact owned network ledger for native retirement."
  }
}
run "both_network_modes_refused" {
  command = plan
  variables { private_subnet_ids = ["subnet-example-a", "subnet-example-b"] }
  expect_failures = [terraform_data.guard]
}
run "no_network_mode_refused" {
  command = plan
  variables { create_private_subnets = null }
  expect_failures = [terraform_data.guard]
}
run "mutual_cidr_overlap_refused" {
  command = plan
  variables { create_private_subnets = { first = { cidr = "10.0.240.0/24", az = "us-west-2a" }, second = { cidr = "10.0.240.128/25", az = "us-west-2b" } } }
  expect_failures = [terraform_data.network_guard]
}
run "foreign_existing_cidr_overlap_refused" {
  command = plan
  override_data {
    target = data.aws_subnets.inventory
    values = { ids = ["subnet-collision"] }
  }
  expect_failures = [terraform_data.network_guard]
}
run "owned_subnets_in_inventory_do_not_block_subsequent_plan" {
  command = plan
  override_data {
    target = data.aws_subnets.inventory
    values = { ids = ["subnet-aaaaaaaaaaaaaaaaa"] }
  }
  override_data {
    target = data.aws_subnet.inventory
    values = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2a", cidr_block = "10.0.240.0/24", map_public_ip_on_launch = false, tags = { Name = "pippen-sbx-example-private-first", "pippen:sandbox" = "true", "pippen:agent" = "example-agent", "pippen:session" = "00000000-0000-4000-8000-000000000000", "proof:run" = "example", "proof:source" = "0000000000000000000000000000000000000000", ManagedBy = "terraform" } }
  }
  assert {
    condition     = length(local.foreign_ranges) == 0
    error_message = "Exact owned subnet identity is omitted only from overlap checks, never adopted."
  }
}
run "cidr_outside_vpc_refused" {
  command = plan
  variables { create_private_subnets = { first = { cidr = "10.1.240.0/24", az = "us-west-2a" }, second = { cidr = "10.0.241.0/24", az = "us-west-2b" } } }
  expect_failures = [terraform_data.network_guard]
}
run "foreign_lease_owned_looking_inventory_refused" {
  command = plan
  override_data {
    target = data.aws_subnets.inventory
    values = { ids = ["subnet-collision"] }
  }
  override_data {
    target = data.aws_subnet.inventory
    values = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2a", cidr_block = "10.0.240.0/24", map_public_ip_on_launch = false, tags = { Name = "pippen-sbx-example-private-first", "pippen:sandbox" = "true", "pippen:agent" = "example-agent", "pippen:session" = "11111111-1111-4111-8111-111111111111", "proof:run" = "example", "proof:source" = "0000000000000000000000000000000000000000", ManagedBy = "terraform" } }
  }
  expect_failures = [terraform_data.network_guard]
}
run "adjacent_small_cidrs_are_accepted" {
  command = plan
  variables { create_private_subnets = { first = { cidr = "10.0.240.0/28", az = "us-west-2a" }, second = { cidr = "10.0.240.16/28", az = "us-west-2b" } } }
  assert {
    condition     = local.new_ranges.first.end + 1 == local.new_ranges.second.start
    error_message = "Adjacent bounded CIDRs must not be mistaken for overlapping ranges."
  }
}
run "owned_same_az_refused" {
  command = plan
  variables { create_private_subnets = { first = { cidr = "10.0.240.0/24", az = "us-west-2a" }, second = { cidr = "10.0.241.0/24", az = "us-west-2a" } } }
  expect_failures = [terraform_data.network_guard]
}
run "unavailable_az_refused" {
  command = plan
  variables { create_private_subnets = { first = { cidr = "10.0.240.0/24", az = "us-west-2a" }, second = { cidr = "10.0.241.0/24", az = "us-west-2c" } } }
  expect_failures = [terraform_data.network_guard]
}
run "non_default_vpc_refused" {
  command = plan
  override_data {
    target = data.aws_vpc.existing
    values = { owner_id = "111111111111", default = false, cidr_block = "10.0.0.0/16" }
  }
  expect_failures = [terraform_data.network_guard]
}
run "foreign_vpc_owner_refused" {
  command = plan
  override_data {
    target = data.aws_vpc.existing
    values = { owner_id = "222222222222", default = true, cidr_block = "10.0.0.0/16" }
  }
  expect_failures = [terraform_data.network_guard]
}
run "noncanonical_cidr_refused" {
  command = plan
  variables { create_private_subnets = { first = { cidr = "10.0.240.1/24", az = "us-west-2a" }, second = { cidr = "10.0.241.0/24", az = "us-west-2b" } } }
  expect_failures = [var.create_private_subnets]
}
