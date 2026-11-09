mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/relay-search-role" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:/aws/opensearch/relay-search" }
  }
  mock_resource "aws_opensearch_domain" {
    defaults = {
      arn      = "arn:aws:es:us-west-2:111111111111:domain/relay-search"
      endpoint = "vpc-relay-search-abc.us-west-2.es.amazonaws.com"
    }
  }
}

variables {
  domain_name        = "relay-search"
  subnet_ids         = ["subnet-a", "subnet-b", "subnet-c"]
  security_group_ids = ["sg-search"]
  master_user_arn    = "arn:aws:iam::111111111111:role/search-admin"
  workload_roles = {
    indexer_service_accounts = [{ cluster_name = "relay", namespace = "agent-relay", service_account = "agent-relay-worker" }]
    reader_service_accounts  = [{ cluster_name = "relay", namespace = "agent-relay", service_account = "agent-relay-alleyoop" }]
  }
}

# Plan only: the domain has prevent_destroy, so an applied run could not be
# torn down.
run "defaults_are_private_and_encrypted" {
  command = plan

  assert {
    condition     = length(one(aws_opensearch_domain.this[0].vpc_options).subnet_ids) == 3
    error_message = "The domain must be a VPC domain."
  }
  assert {
    condition     = one(aws_opensearch_domain.this[0].encrypt_at_rest).enabled && one(aws_opensearch_domain.this[0].node_to_node_encryption).enabled
    error_message = "Encryption at rest and node-to-node encryption must be on."
  }
  assert {
    condition     = one(aws_opensearch_domain.this[0].domain_endpoint_options).enforce_https
    error_message = "HTTPS must be enforced."
  }
  assert {
    condition = (
      one(aws_opensearch_domain.this[0].advanced_security_options).enabled &&
      !one(aws_opensearch_domain.this[0].advanced_security_options).anonymous_auth_enabled &&
      !one(aws_opensearch_domain.this[0].advanced_security_options).internal_user_database_enabled
    )
    error_message = "Fine-grained access control with IAM master user, no anonymous or internal users."
  }
  assert {
    condition     = one(aws_opensearch_domain.this[0].cluster_config).zone_awareness_enabled && one(one(aws_opensearch_domain.this[0].cluster_config).zone_awareness_config).availability_zone_count == 3
    error_message = "Zone awareness follows the subnet count."
  }
  assert {
    condition     = length(aws_iam_role.workload) == 2 && length(aws_eks_pod_identity_association.workload) == 2
    error_message = "Indexer and reader roles with their Pod Identity associations."
  }
  assert {
    condition     = !contains(jsondecode(aws_iam_role_policy.workload["reader"].policy).Statement[0].Action, "es:ESHttpPut") && !contains(jsondecode(aws_iam_role_policy.workload["reader"].policy).Statement[0].Action, "es:ESHttpDelete")
    error_message = "The reader role must not write."
  }
}

run "access_policy_names_principals" {
  command = plan

  variables {
    workload_roles            = { create = false }
    additional_principal_arns = ["arn:aws:iam::111111111111:role/indexer"]
  }

  assert {
    condition     = toset(flatten([jsondecode(aws_opensearch_domain_policy.this.access_policies).Statement[0].Principal.AWS])) == toset(["arn:aws:iam::111111111111:role/indexer", "arn:aws:iam::111111111111:role/search-admin"])
    error_message = "The access policy names exactly the listed principals and the master user, never *."
  }
  assert {
    condition     = length(aws_iam_role.workload) == 0 && length(aws_iam_role_policy.workload) == 0 && length(aws_eks_pod_identity_association.workload) == 0
    error_message = "External identities must not author search IAM or Pod Identity associations."
  }
}

run "instance_count_follows_azs" {
  command = plan

  variables {
    instance_count = 4
  }

  expect_failures = [aws_opensearch_domain.this]
}

run "standby_needs_three_azs" {
  command = plan

  variables {
    subnet_ids                    = ["subnet-a", "subnet-b"]
    multi_az_with_standby_enabled = true
  }

  expect_failures = [aws_opensearch_domain.this]
}

run "two_azs_default_to_four_nodes" {
  command = plan

  variables {
    subnet_ids = ["subnet-a", "subnet-b"]
  }

  assert {
    condition     = one(aws_opensearch_domain.this[0].cluster_config).instance_count == 4
    error_message = "Two AZs default to four data nodes."
  }
}

run "master_user_is_required" {
  command = plan

  variables {
    master_user_arn = null
  }

  expect_failures = [var.master_user_arn]
}
