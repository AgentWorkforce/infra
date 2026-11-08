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
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:pippen-sbx-example-runtime-abcdef" } }
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
  deadline           = "2099-01-01T00:00:00.000Z"
  guest_sources      = { composition_commit = "292359f0c68b1e4615704fd51d303b7f6b4db445", manifest_sha256 = "3333333333333333333333333333333333333333333333333333333333333333", generation = "7d64ae1f74670530fd6443fad7d6cc9ac11776055941821ef79f8501fb2d7879" }
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
  payload_version_id = null # F1: no compute until a reviewed activation artifact exists
  rds_ca_sha256      = "0000000000000000000000000000000000000000000000000000000000000000"
}
run "actual_modules_private_managed_secret_and_versioned_bucket" {
  command = apply
  assert {
    condition     = output.proof_contract.sentinel.version_id == "synthetic-sentinel-version" && aws_s3_object.sentinel.server_side_encryption == "aws:kms"
    error_message = "The sentinel contract requires a real version reference and explicit SSE-KMS."
  }
  assert {
    condition     = module.postgres.master_user_secret_arn != null && module.postgres.initial_database == "relaycontrol" && output.proof_contract.database.retained_automated_backups && output.proof_contract.database.skip_final_snapshot
    error_message = "Expose only a managed-secret reference and explicit module cleanup obligations."
  }
  assert {
    condition     = aws_iam_role.verifier.path == "/pippen/workload/" && aws_iam_role.verifier.permissions_boundary == "arn:aws:iam::111111111111:policy/pippen-agent-session-boundary" && startswith(aws_iam_instance_profile.verifier.name, "eks-")
    error_message = "Verifier must retain existing Pippen path/boundary/profile."
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
run "application_binding_comes_from_postgres_layout" {
  command = plan
  assert {
    condition     = output.application_binding.database == "hoopdb" && output.application_binding.schema == "sessions" && output.application_binding.owner == "hoop" && output.application_binding.runtime == "sessions_pipeline_runtime" && output.application_binding.provisioning_executor == "proof_admin" && output.application_binding.activation == null
    error_message = "Application identities must come from the reviewed postgres-layout hoopdb binding, distinct from the RDS master."
  }
  assert {
    condition     = !contains(flatten([for b in values(module.layout.bindings) : [b.migration_role, b.runtime_role]]), "proof_admin") && module.layout.topology.application_sql_ready == false && output.application_sql_ready == false
    error_message = "The RDS master must be a forbidden application role and application SQL must stay not-ready."
  }
}
run "application_execution_refused_without_reviewed_activation" {
  command = plan
  variables { payload_version_id = "synthetic-transport-version" }
  expect_failures = [terraform_data.application_gate]
}
run "unregistered_activation_artifact_still_refused" {
  command = plan
  variables {
    payload_version_id     = "synthetic-transport-version"
    application_activation = { sessions_commit = "1111111111111111111111111111111111111111", artifact_sha256 = "2222222222222222222222222222222222222222222222222222222222222222", generation = "3333333333333333333333333333333333333333333333333333333333333333", contract = "unreviewed" }
  }
  expect_failures = [terraform_data.application_gate]
}
run "malformed_activation_refused" {
  command = plan
  variables { application_activation = { sessions_commit = "not-a-commit", artifact_sha256 = "x", generation = "y", contract = "Bad Contract" } }
  expect_failures = [var.application_activation]
}
run "restore_requires_explicit_checkpoint_and_remains_private" {
  command = plan
  variables { restore_checkpoint = { seed_receipt_version_id = "synthetic-seed-version", seed_receipt_sha256 = "1111111111111111111111111111111111111111111111111111111111111111", secret_version_id = "00000000-0000-4000-8000-000000000000", runtime_secret_version_id = "11111111-1111-4111-8111-111111111111", seed_evidence_sha256 = "2222222222222222222222222222222222222222222222222222222222222222" } }
  assert {
    condition     = length(aws_db_snapshot.marker) == 1 && length(aws_db_instance.restored) == 1 && !aws_db_instance.restored[0].publicly_accessible && aws_db_instance.restored[0].deletion_protection && aws_db_instance.restored[0].skip_final_snapshot && aws_db_instance.restored[0].manage_master_user_password == null && aws_db_instance.restored[0].password == null
    error_message = "Restore must use a TF-owned snapshot with no TF password and explicit protection/lifecycle."
  }
}
run "retirement_releases_deletion_protection_only_by_input" {
  command = plan
  variables {
    retire             = true
    restore_checkpoint = { seed_receipt_version_id = "synthetic-seed-version", seed_receipt_sha256 = "1111111111111111111111111111111111111111111111111111111111111111", secret_version_id = "00000000-0000-4000-8000-000000000000", runtime_secret_version_id = "11111111-1111-4111-8111-111111111111", seed_evidence_sha256 = "2222222222222222222222222222222222222222222222222222222222222222" }
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

run "runtime_container_is_empty_scoped_and_deadline_bound" {
  command = apply
  assert {
    condition     = aws_secretsmanager_secret.runtime.recovery_window_in_days == 0 && aws_secretsmanager_secret.runtime.kms_key_id == null && output.proof_contract.runtime_secret.arn == aws_secretsmanager_secret.runtime.arn && output.proof_contract.runtime_secret.name == "pippen-sbx-example-runtime"
    error_message = "Only an empty owned AWS-managed-encrypted runtime container is Terraform-owned; no credential versions or recovery leftovers."
  }
  assert {
    condition     = length([for statement in jsondecode(aws_iam_role_policy.verifier.policy).Statement : statement if statement.Effect == "Allow" && statement.Action == "secretsmanager:PutSecretValue" && statement.Resource == aws_secretsmanager_secret.runtime.arn]) == 1
    error_message = "Host may publish only to its exact new runtime ARN."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.verifier.policy).Statement : try(statement.Condition.DateLessThan["aws:CurrentTime"] == var.deadline, false) if statement.Effect == "Allow"])
    error_message = "Every workload grant must expire at the original immutable deadline."
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.verifier.policy, "receipts/seed.pending.json") && output.proof_contract.guest_sources == var.guest_sources
    error_message = "Pending intent receipt scope and original guest source identity cannot be dropped."
  }
}
run "wrong_original_guest_commit_refused" {
  command = plan
  variables { guest_sources = { composition_commit = "ffffffffffffffffffffffffffffffffffffffff", manifest_sha256 = "3333333333333333333333333333333333333333333333333333333333333333", generation = "7d64ae1f74670530fd6443fad7d6cc9ac11776055941821ef79f8501fb2d7879" } }
  expect_failures = [var.guest_sources]
}
run "malformed_workload_deadline_refused" {
  command = plan
  variables { deadline = "not-a-deadline" }
  expect_failures = [var.deadline]
}
run "historical_runtime_reference_required_for_restore" {
  command = plan
  variables { restore_checkpoint = { seed_receipt_version_id = "synthetic-seed-version", seed_receipt_sha256 = "1111111111111111111111111111111111111111111111111111111111111111", secret_version_id = "00000000-0000-4000-8000-000000000000", runtime_secret_version_id = "null", seed_evidence_sha256 = "2222222222222222222222222222222222222222222222222222222222222222" } }
  expect_failures = [var.restore_checkpoint]
}
