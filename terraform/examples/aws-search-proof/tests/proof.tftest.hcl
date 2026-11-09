mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-00000000-0000-4000-8000-000000000000" } }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_subnet" { defaults = { owner_id = "111111111111", vpc_id = "vpc-example", map_public_ip_on_launch = false, availability_zone = "us-west-2a", available_ip_address_count = 20 } }
  mock_data "aws_security_group" { defaults = { arn = "arn:aws:ec2:us-west-2:111111111111:security-group/sg-client", vpc_id = "vpc-example" } }
  mock_resource "aws_opensearch_domain" { defaults = { arn = "arn:aws:es:us-west-2:111111111111:domain/synthetic", endpoint = "vpc-synthetic.us-west-2.es.amazonaws.com" } }
}
override_data {
  target = data.aws_security_group.domain
  values = { arn = "arn:aws:ec2:us-west-2:111111111111:security-group/sg-domain", vpc_id = "vpc-example" }
}
override_data {
  target = data.aws_subnet.second
  values = { owner_id = "111111111111", vpc_id = "vpc-example", map_public_ip_on_launch = false, availability_zone = "us-west-2b", available_ip_address_count = 20 }
}
variables {
  account_id                = "111111111111"
  region                    = "us-west-2"
  pippen                    = { agent = "synthetic-agent", session_id = "00000000-0000-4000-8000-000000000000" }
  source_sha                = "0000000000000000000000000000000000000000"
  approved_tag_keys         = ["pippen:sandbox", "pippen:agent", "pippen:session", "proof:source", "Environment", "EnvironmentClass", "ManagedBy"]
  vpc_id                    = "vpc-example"
  subnet_ids                = ["subnet-a"]
  domain_security_group_id  = "sg-domain"
  client_security_group_ids = ["sg-client"]
  roles                     = { admin = "arn:aws:iam::111111111111:role/runtime/admin", indexer = "arn:aws:iam::111111111111:role/runtime/indexer", reader = "arn:aws:iam::111111111111:role/runtime/reader" }
  engine_version            = "OpenSearch_2.19"
}
run "first_create_policy_arn_is_known_before_apply" {
  command = plan
  assert {
    condition     = jsondecode(module.search.indexer_policy_json).Statement[0].Resource == ["arn:aws:es:${var.region}:${var.account_id}:domain/${local.domain_name}/*"] && jsondecode(module.search.reader_policy_json).Statement[0].Resource == ["arn:aws:es:${var.region}:${var.account_id}:domain/${local.domain_name}/*"]
    error_message = "A first-create plan must resolve permission-bearing domain ARNs without overriding nested account/region/partition data."
  }
}
run "actual_module_explicit_external_roles_and_honest_plan_identity" {
  command = apply
  assert {
    condition     = output.proof_contract.disposable && output.proof_contract.domain_name == "pippen-sbx-${substr(sha256(var.pippen.session_id), 0, 10)}-search" && module.search.indexer_role_arn == null && module.search.reader_role_arn == null && length(module.search.pod_identity_association_ids) == 0
    error_message = "Use the actual disposable module, deterministic lease name and external identities only."
  }
  assert {
    condition     = output.proof_contract.plan_caller_arn != output.proof_contract.expected_apply_caller_arn && length(output.proof_contract.tags) == 7 && output.proof_contract.tags["proof:source"] == var.source_sha && output.proof_contract.roles.admin != output.proof_contract.roles.reader
    error_message = "Record common plan identity honestly; never equate it with capability apply evidence or drop immutable source ownership."
  }
}
run "two_private_az_subnets_supported" {
  command = plan
  variables { subnet_ids = ["subnet-a", "subnet-b"] }
}
run "foreign_account_refused" {
  command = plan
  variables { account_id = "222222222222" }
  expect_failures = [terraform_data.guard]
}
run "wrong_lease_refused" {
  command = plan
  variables { pippen = { agent = "synthetic-agent", session_id = "11111111-1111-4111-8111-111111111111" } }
  expect_failures = [terraform_data.guard]
}
run "wrong_region_refused" {
  command = plan
  variables { region = "us-east-1" }
  expect_failures = [terraform_data.guard]
}
run "foreign_role_refused" {
  command = plan
  variables { roles = { admin = "arn:aws:iam::222222222222:role/admin", indexer = "arn:aws:iam::111111111111:role/runtime/indexer", reader = "arn:aws:iam::111111111111:role/runtime/reader" } }
  expect_failures = [terraform_data.guard]
}
run "shared_admin_reader_refused" {
  command = plan
  variables { roles = { admin = "arn:aws:iam::111111111111:role/runtime/reader", indexer = "arn:aws:iam::111111111111:role/runtime/indexer", reader = "arn:aws:iam::111111111111:role/runtime/reader" } }
  expect_failures = [terraform_data.guard]
}
run "control_role_as_admin_refused" {
  command = plan
  variables { roles = { admin = "arn:aws:iam::111111111111:role/pippen/provisioning/search-control-v1-00000000-0000-4000-8000-000000000000", indexer = "arn:aws:iam::111111111111:role/runtime/indexer", reader = "arn:aws:iam::111111111111:role/runtime/reader" } }
  expect_failures = [terraform_data.guard]
}
run "public_subnet_refused" {
  command = plan
  override_data {
    target = data.aws_subnet.first
    values = { owner_id = "111111111111", vpc_id = "vpc-example", map_public_ip_on_launch = true, availability_zone = "us-west-2a", available_ip_address_count = 20 }
  }
  expect_failures = [terraform_data.guard]
}
run "same_az_refused" {
  command = plan
  variables { subnet_ids = ["subnet-a", "subnet-b"] }
  override_data {
    target = data.aws_subnet.second
    values = { owner_id = "111111111111", vpc_id = "vpc-example", map_public_ip_on_launch = false, availability_zone = "us-west-2a", available_ip_address_count = 20 }
  }
  expect_failures = [terraform_data.guard]
}
run "unapproved_source_tag_refused" {
  command = plan
  variables { approved_tag_keys = ["pippen:sandbox", "pippen:agent", "pippen:session", "other", "Environment", "EnvironmentClass", "ManagedBy"] }
  expect_failures = [terraform_data.guard]
}
run "reserved_tag_case_alias_refused" {
  command = plan
  variables { approved_tag_keys = ["pippen:sandbox", "pippen:agent", "pippen:session", "proof:source", "Environment", "EnvironmentClass", "ManagedBy", "Pippen:Agent"] }
  expect_failures = [var.approved_tag_keys]
}
