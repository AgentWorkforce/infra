mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:iam::111111111111:role/example-operator" }
  }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_resource "aws_eks_cluster" {
    defaults = { arn = "arn:aws:eks:us-west-2:111111111111:cluster/example" }
  }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:example" } }
  mock_resource "aws_launch_template" { defaults = { id = "lt-0123456789abcdef0", latest_version = 1 } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111111111111:role/example" } }
}
variables {
  account_id               = "111111111111"
  region                   = "us-west-2"
  environment              = "dev"
  kubernetes_version       = "1.35"
  node_ami_release_version = "1.35.0-20260101"
  addon_versions = {
    vpc-cni                = "v1.21.0-eksbuild.1"
    kube-proxy             = "v1.35.0-eksbuild.1"
    coredns                = "v1.12.0-eksbuild.1"
    eks-pod-identity-agent = "v1.3.0-eksbuild.1"
    aws-ebs-csi-driver     = "v1.40.0-eksbuild.1"
  }
  subnets = {
    us-west-2a = { public_cidr = "10.80.0.0/24", private_cidr = "10.80.16.0/20" }
    us-west-2b = { public_cidr = "10.80.1.0/24", private_cidr = "10.80.32.0/20" }
  }
  actor_availability_zone = "us-west-2a"
  operator_cidrs          = ["192.0.2.0/24"]
  operator_role_arns      = ["arn:aws:iam::111111111111:role/example-operator"]
  kms_key_arn             = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-0000-0000-000000000000"
}
run "private_foundation_contract" {
  command = apply
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access && !aws_eks_cluster.this.vpc_config[0].endpoint_public_access && !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions && aws_eks_cluster.this.deletion_protection
    error_message = "API must be private and creator must not gain implicit admin."
  }
  assert {
    condition     = length(output.private_subnet_ids) == 2 && length(output.search_subnet_ids) == 2 && output.namespace == "agent-relay-dev" && output.eks_cluster_name == "agent-relay-dev"
    error_message = "PR60 cluster/subnet/namespace composition must match."
  }
  assert {
    condition     = output.database_security_group_ids == [aws_security_group.this["database"].id] && output.search_security_group_ids == [aws_security_group.this["search"].id] && output.function_security_group_ids == [aws_security_group.this["function"].id]
    error_message = "Data/function security groups must use the destination/source contracts."
  }
  assert {
    condition     = alltrue([for az in keys(var.subnets) : aws_route.nat[az].nat_gateway_id == aws_nat_gateway.this[az].id && aws_nat_gateway.this[az].subnet_id == aws_subnet.public[az].id && aws_route_table_association.private[az].subnet_id == aws_subnet.private[az].id && !aws_subnet.private[az].map_public_ip_on_launch])
    error_message = "Every private AZ must have its own public NAT route and no public address assignment."
  }
  assert {
    condition     = aws_eks_node_group.this["actors"].labels["durable-actors/role"] == "actor-host" && one(aws_eks_node_group.this["actors"].taint).key == "durable-actors/actor-host" && one(aws_eks_node_group.this["actors"].taint).effect == "NO_SCHEDULE" && aws_eks_node_group.this["actors"].subnet_ids == toset([aws_subnet.private["us-west-2a"].id]) && output.actor_profile.sandbox.runtimeClassName == ""
    error_message = "Actor capacity must match the existing first-party profile in one explicit AZ."
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.metadata_options[0].http_tokens == "required" && lt.metadata_options[0].http_put_response_hop_limit == 1 && one(lt.block_device_mappings).ebs[0].encrypted && one(lt.block_device_mappings).ebs[0].kms_key_id == var.kms_key_arn]) && output.storage_class_manifest.reclaimPolicy == "Retain"
    error_message = "Node disks must be encrypted, IMDS locked down, and persistent data retained."
  }
  assert {
    condition     = aws_eks_pod_identity_association.ebs.namespace == "kube-system" && aws_eks_pod_identity_association.ebs.service_account == "ebs-csi-controller-sa" && aws_eks_pod_identity_association.cni.service_account == "aws-node" && aws_vpc_endpoint.eks_auth.private_dns_enabled
    error_message = "CSI and CNI must use their own Pod Identities and private EKS Auth."
  }
  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.database : rule.from_port == 5432 && rule.to_port == 5432 && rule.cidr_ipv4 == null]) && alltrue([for rule in aws_vpc_security_group_ingress_rule.search : rule.from_port == 443 && rule.to_port == 443 && rule.cidr_ipv4 == null])
    error_message = "Data access must reference environment source SGs, never public CIDRs."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.flow.policy).Statement[0].Action, "logs:CreateLogGroup") && jsondecode(aws_iam_role_policy.flow.policy).Statement[1].Action == ["logs:DescribeLogGroups"] && jsondecode(aws_iam_role_policy.flow.policy).Statement[1].Condition.StringEquals["aws:RequestedRegion"] == var.region
    error_message = "Flow logs require scoped publishing and region-limited DescribeLogGroups."
  }
  assert {
    condition     = !contains(keys(local.managed_policies), "node-cni") && aws_iam_role_policy_attachment.this["cni"].role == aws_iam_role.this["cni"].name && aws_iam_role_policy_attachment.this["ebs"].role == aws_iam_role.this["ebs"].name
    error_message = "CNI and CSI permissions must stay off the shared node role."
  }
}
run "bounded_public_api" {
  command = plan
  variables { public_api_enabled = true }
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["192.0.2.0/24"])
    error_message = "Public API may only use explicit operator CIDRs."
  }
}
run "single_az_search_choice" {
  command = apply
  variables { search_az_count = 1 }
  assert {
    condition     = output.search_subnet_ids == [aws_subnet.private["us-west-2a"].id] && length(output.private_subnet_ids) == 2
    error_message = "Search may select one AZ without narrowing the RDS subnet set."
  }
}
run "three_az_search_choice" {
  command = apply
  variables {
    search_az_count = 3
    subnets = {
      us-west-2a = { public_cidr = "10.80.0.0/24", private_cidr = "10.80.16.0/20" }
      us-west-2b = { public_cidr = "10.80.1.0/24", private_cidr = "10.80.32.0/20" }
      us-west-2c = { public_cidr = "10.80.2.0/24", private_cidr = "10.80.48.0/20" }
    }
  }
  assert {
    condition     = length(output.search_subnet_ids) == 3 && length(aws_nat_gateway.this) == 3
    error_message = "Three AZs must compose with OpenSearch and dedicated NATs."
  }
}
run "pippen_lease_contract" {
  command = apply
  variables {
    name_prefix = "pippen-sbx-ar"
    pippen      = { agent = "example-agent", session_id = "example-session" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-example-session" }
  }
  assert {
    condition     = alltrue([for r in aws_iam_role.this : r.path == "/pippen/workload/" && r.permissions_boundary == "arn:aws:iam::111111111111:policy/pippen-agent-session-boundary" && r.tags["pippen:session"] == "example-session"]) && aws_vpc.this.tags["pippen:sandbox"] == "true" && aws_iam_role.flow.path == "/pippen/workload/" && aws_iam_role.flow.permissions_boundary == local.boundary
    error_message = "Pippen roles must use the workload path, exact boundary and reserved lease tags."
  }
}
run "reject_wrong_account" {
  command = plan
  # Change only the observed caller. Changing var.account_id would also make
  # the operator-role/KMS guard fail and mask removal of the caller guard.
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "222222222222", arn = "arn:aws:iam::222222222222:role/example-operator" }
  }
  expect_failures = [terraform_data.guard]
}
run "reject_wrong_region" {
  command = plan
  # Keep subnet AZs and KMS inputs valid for the reviewed target; only the
  # observed provider region may trigger the expected failure.
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }
  expect_failures = [terraform_data.guard]
}
run "reject_invalid_environment" {
  command = plan
  variables {
    environment = "../production"
  }
  expect_failures = [var.environment]
}
run "reject_invalid_public_network" {
  command = plan
  variables {
    operator_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.operator_cidrs]
}
run "reject_public_api_without_cidrs" {
  command = plan
  variables {
    public_api_enabled          = true
    operator_cidrs              = []
    operator_security_group_ids = ["sg-example-runner"]
  }
  expect_failures = [terraform_data.guard]
}
run "reject_no_operator_path" {
  command = plan
  variables {
    operator_cidrs = []
  }
  expect_failures = [terraform_data.guard]
}
run "reject_wrong_operator_account" {
  command = plan
  variables {
    operator_role_arns = ["arn:aws:iam::222222222222:role/example"]
  }
  expect_failures = [terraform_data.guard]
}
run "reject_pippen_wrong_name" {
  command = plan
  variables {
    pippen = { agent = "example", session_id = "example-session" }
  }
  # A valid lease caller isolates the unscoped name_prefix rejection. Without
  # this override the wrong caller could hide a removed prefix check.
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-example-session" }
  }
  expect_failures = [terraform_data.guard]
}
run "reject_pippen_wrong_lease" {
  command = plan
  variables {
    name_prefix = "pippen-sbx-ar"
    pippen      = { agent = "example", session_id = "other-session" }
  }
  expect_failures = [terraform_data.guard]
}
run "reject_reserved_tags" {
  command = plan
  variables {
    tags = { "pippen:session" = "spoofed" }
  }
  expect_failures = [var.tags]
}
run "reject_one_az_is_invalid" {
  command = plan
  variables {
    subnets         = { us-west-2a = { public_cidr = "10.80.0.0/24", private_cidr = "10.80.16.0/20" } }
    search_az_count = 1
  }
  expect_failures = [var.subnets]
}

run "reject_overlap" {
  command = plan
  variables {
    subnets = {
      us-west-2a = { public_cidr = "10.80.0.0/24", private_cidr = "10.80.16.0/20" }
      us-west-2b = { public_cidr = "10.80.0.0/24", private_cidr = "10.80.32.0/20" }
    }
  }
  expect_failures = [terraform_data.guard]
}
run "reject_outside_vpc" {
  command = plan
  variables { vpc_cidr = "10.90.0.0/16" }
  expect_failures = [terraform_data.guard]
}
run "reject_actor_az" {
  command = plan
  variables { actor_availability_zone = "us-west-2z" }
  expect_failures = [terraform_data.guard]
}
run "reject_search_az_count" {
  command = plan
  variables { search_az_count = 3 }
  expect_failures = [terraform_data.guard]
}

run "reject_bad_kubernetes_version" {
  command = plan
  variables { kubernetes_version = "latest" }
  expect_failures = [var.kubernetes_version]
}
run "reject_incomplete_addon_versions" {
  command = plan
  variables { addon_versions = {} }
  expect_failures = [var.addon_versions]
}
run "reject_kms_other_region" {
  command = plan
  variables { kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  expect_failures = [terraform_data.guard]
}
run "reject_bad_pippen_identity" {
  command = plan
  variables { pippen = { agent = "", session_id = "" } }
  expect_failures = [var.pippen]
}

run "reviewed_retirement_toggle" {
  command = plan
  variables { deletion_protection = false }
  assert {
    condition     = !aws_eks_cluster.this.deletion_protection
    error_message = "Reviewed EKS retirement must be able to disable API deletion protection explicitly."
  }
}
