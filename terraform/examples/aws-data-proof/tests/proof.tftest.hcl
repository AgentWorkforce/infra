mock_provider "aws" {
  mock_data "aws_vpc" { defaults = { owner_id = "111111111111", default = true, cidr_block = "10.0.0.0/16" } }
  mock_data "aws_availability_zones" { defaults = { names = ["us-west-2a", "us-west-2b"] } }
  mock_data "aws_subnets" { defaults = { ids = [] } }
  mock_data "aws_subnet" { defaults = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2a", map_public_ip_on_launch = false, cidr_block = "10.0.240.0/24", tags = {} } }
  mock_resource "aws_launch_template" { defaults = { id = "lt-0123456789abcdef0", latest_version = 1 } }
  mock_resource "aws_security_group" { defaults = { id = "sg-0123456789abcdef0" } }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-00000000-0000-4000-8000-000000000000" }
  }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_data "aws_ami" { defaults = { architecture = "arm64", root_device_type = "ebs", virtualization_type = "hvm", name = "al2023-ami-example", root_device_name = "/dev/xvda" } }
  mock_resource "aws_db_instance" {
    defaults = { address = "synthetic.example", arn = "arn:aws:rds:us-west-2:111111111111:db:pippen-sbx-example-pg", master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds-example", secret_status = "active", kms_key_id = "example" }] }
  }
  mock_resource "aws_s3_bucket" { defaults = { arn = "arn:aws:s3:::pippen-sbx-example-111111111111-us-west-2", id = "pippen-sbx-example-111111111111-us-west-2" } }
  mock_resource "aws_s3_object" { defaults = { version_id = "synthetic-sentinel-version" } }
}
mock_provider "random" {}
override_resource {
  target = aws_security_group.verifier
  values = { id = "sg-11111111111111111" }
}
override_resource {
  target = aws_subnet.private_first
  values = { id = "subnet-aaaaaaaaaaaaaaaaa" }
}
override_resource {
  target = aws_subnet.private_second
  values = { id = "subnet-bbbbbbbbbbbbbbbbb" }
}
override_data {
  target = data.aws_subnet.private_first
  values = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2a", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.private_second
  values = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2b", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.host
  values = { owner_id = "111111111111", vpc_id = "vpc-example" }
}
variables {
  account_id         = "111111111111"
  region             = "us-west-2"
  run_id             = "example"
  pippen             = { agent = "example-agent", session_id = "00000000-0000-4000-8000-000000000000" }
  vpc_id             = "vpc-example"
  private_subnet_ids = ["subnet-example-a", "subnet-example-b"]
  host_subnet_id     = "subnet-example-host"
  ami_id             = "ami-example"
  postgres_version   = "17.5"
  source_sha         = "0000000000000000000000000000000000000000"
  payload_sha256     = "0000000000000000000000000000000000000000000000000000000000000000"
  payload_version_id = "synthetic-transport-version"
  rds_ca_sha256      = "0000000000000000000000000000000000000000000000000000000000000000"
}
run "actual_modules_private_managed_secret_and_versioned_bucket" {
  command = apply
  assert {
    condition     = output.proof_contract.sentinel.version_id == "synthetic-sentinel-version" && aws_s3_object.sentinel.server_side_encryption == "aws:kms"
    error_message = "The sentinel contract requires a real version reference and explicit SSE-KMS."
  }
  assert {
    condition     = module.postgres.master_user_secret_arn != null && module.postgres.initial_database == "moduleproof" && output.proof_contract.database.retained_automated_backups && output.proof_contract.database.skip_final_snapshot
    error_message = "Expose only a managed-secret reference and explicit module cleanup obligations."
  }
  assert {
    condition     = aws_iam_role.verifier.path == "/pippen/workload/" && aws_iam_role.verifier.permissions_boundary == "arn:aws:iam::111111111111:policy/pippen-agent-session-boundary" && startswith(aws_iam_instance_profile.verifier.name, "eks-") && aws_instance.verifier[0].instance_initiated_shutdown_behavior == "terminate"
    error_message = "Verifier must retain existing Pippen path/boundary/profile and shutdown retirement."
  }
  assert {
    condition     = aws_launch_template.verifier.iam_instance_profile[0].name == aws_iam_instance_profile.verifier.name && jsondecode(aws_iam_role.verifier.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com"
    error_message = "The instance must bind the exact EC2-only verifier identity through its launch template."
  }
  assert {
    condition     = aws_launch_template.verifier.metadata_options[0].http_tokens == "required" && aws_launch_template.verifier.metadata_options[0].http_put_response_hop_limit == 1 && one(aws_launch_template.verifier.block_device_mappings).ebs[0].encrypted && one(aws_launch_template.verifier.block_device_mappings).ebs[0].delete_on_termination && aws_vpc_security_group_ingress_rule.database.referenced_security_group_id == aws_security_group.verifier.id && aws_vpc_security_group_ingress_rule.database.from_port == 5432 && length(aws_security_group.verifier.ingress) == 0
    error_message = "Private database SG peer, no host ingress, IMDSv2 and encrypted ephemeral root are required."
  }
  assert {
    condition     = output.proof_contract.phase == "seed" && output.proof_contract.snapshot == null && strcontains(aws_iam_role_policy.verifier.policy, "s3:DeleteObjectVersion") && !strcontains(aws_iam_role_policy.verifier.policy, "secretsmanager:*") && aws_s3_object.sentinel.key == "unrelated/sentinel"
    error_message = "Seed must be isolated, version cleanup scoped and unrelated sentinel preserved."
  }
}
run "restore_requires_explicit_checkpoint_and_remains_private" {
  command = plan
  variables { restore_checkpoint = { seed_receipt_version_id = "synthetic-seed-version", seed_receipt_sha256 = "1111111111111111111111111111111111111111111111111111111111111111", secret_version_id = "00000000-0000-4000-8000-000000000000" } }
  assert {
    condition     = length(aws_db_snapshot.marker) == 1 && length(aws_db_instance.restored) == 1 && !aws_db_instance.restored[0].publicly_accessible && aws_db_instance.restored[0].deletion_protection && aws_db_instance.restored[0].skip_final_snapshot && aws_db_instance.restored[0].manage_master_user_password == null && aws_db_instance.restored[0].password == null
    error_message = "Restore must use a TF-owned snapshot with no TF password and explicit protection/lifecycle."
  }
}
run "retirement_releases_deletion_protection_only_by_input" {
  command = plan
  variables {
    retire             = true
    restore_checkpoint = { seed_receipt_version_id = "synthetic-seed-version", seed_receipt_sha256 = "1111111111111111111111111111111111111111111111111111111111111111", secret_version_id = "00000000-0000-4000-8000-000000000000" }
  }
  assert {
    condition     = !aws_db_instance.restored[0].deletion_protection && output.proof_contract.database.skip_final_snapshot && length(aws_instance.verifier) == 0
    error_message = "Retirement release must be an explicit reviewed phase with no implicit final snapshots."
  }
}
run "data_provisioning_has_no_compute_before_version_pin" {
  command = plan
  variables { payload_version_id = null }
  assert {
    condition     = length(aws_instance.verifier) == 0 && output.proof_contract.compute == null
    error_message = "Provision data without compute until the exact transport version exists."
  }
}
run "public_subnet_refused" {
  command = plan
  override_data {
    target = data.aws_subnet.private_second
    values = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2b", map_public_ip_on_launch = true }
  }
  expect_failures = [terraform_data.guard]
}
run "wrong_ami_architecture" {
  command = plan
  override_data {
    target = data.aws_ami.host
    values = { architecture = "x86_64", root_device_type = "ebs", virtualization_type = "hvm", name = "al2023-ami-example" }
  }
  expect_failures = [terraform_data.guard]
}
run "wrong_account" {
  command = plan
  variables { account_id = "222222222222" }
  expect_failures = [terraform_data.guard]
}
run "wrong_lease" {
  command = plan
  variables { pippen = { agent = "example-agent", session_id = "11111111-1111-4111-8111-111111111111" } }
  expect_failures = [terraform_data.guard]
}
run "wrong_vpc" {
  command = plan
  variables { vpc_id = "vpc-foreign" }
  expect_failures = [terraform_data.guard]
}
run "wrong_postgres_major" {
  command = plan
  variables { postgres_version = "16.9" }
  expect_failures = [var.postgres_version]
}
run "same_az_refused" {
  command = plan
  override_data {
    target = data.aws_subnet.private_second
    values = { owner_id = "111111111111", vpc_id = "vpc-example", availability_zone = "us-west-2a", map_public_ip_on_launch = false }
  }
  expect_failures = [terraform_data.guard]
}
