mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111" } }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_resource "aws_opensearch_domain" {
    defaults = { arn = "arn:aws:es:us-west-2:111111111111:domain/relay-search", endpoint = "vpc-synthetic.us-west-2.es.amazonaws.com" }
  }
}
variables {
  domain_name                = "relay-search"
  subnet_ids                 = ["subnet-synthetic"]
  security_group_ids         = ["sg-synthetic"]
  master_user_arn            = "arn:aws:iam::111111111111:role/search-admin"
  workload_roles             = { create = false }
  additional_principal_arns  = ["arn:aws:iam::111111111111:role/search-indexer", "arn:aws:iam::111111111111:role/search-reader"]
  disposable                 = true
  instance_count             = 1
  dedicated_master_enabled   = false
  log_publishing             = []
  create_log_resource_policy = false
}
run "explicit_disposable_uses_same_security_and_external_identities" {
  command = apply
  assert {
    condition     = length(aws_opensearch_domain.this) == 0 && length(aws_opensearch_domain.disposable) == 1 && one(aws_opensearch_domain.disposable[0].encrypt_at_rest).enabled && one(aws_opensearch_domain.disposable[0].node_to_node_encryption).enabled && one(aws_opensearch_domain.disposable[0].domain_endpoint_options).enforce_https && one(aws_opensearch_domain.disposable[0].advanced_security_options).enabled && !one(aws_opensearch_domain.disposable[0].advanced_security_options).internal_user_database_enabled && !one(aws_opensearch_domain.disposable[0].advanced_security_options).anonymous_auth_enabled
    error_message = "Disposable mode must retain encryption/TLS/FGAC and never create a protected domain too."
  }
  assert {
    condition     = length(aws_iam_role.workload) == 0 && length(aws_iam_role_policy.workload) == 0 && length(aws_eks_pod_identity_association.workload) == 0 && length(aws_cloudwatch_log_group.this) == 0 && length(aws_cloudwatch_log_resource_policy.this) == 0
    error_message = "The bounded disposable path creates no identity, log policy or association."
  }
}
# Native test teardown destroys the applied mocked disposable domain, with its
# state intact. A literal guard on this selected branch would make teardown fail.
