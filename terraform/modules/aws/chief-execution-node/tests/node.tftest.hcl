mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-12345678", map_public_ip_on_launch = false }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-12345678" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:node/secret-AbCdEf" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/node", id = "node" }
  }
}

variables {
  name           = "node"
  subnet_id      = "subnet-12345678"
  kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-0000-0000-000000000000"
  relay_base_url = "https://cast.example.com"
  node_runtime = {
    url    = "https://nodejs.org/dist/v22.23.4/node-v22.23.4-linux-x64.tar.xz"
    sha256 = "1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce"
  }
  relay_node = {
    url    = "https://github.com/AgentWorkforce/relay/releases/download/v17.2.1/agent-relay-node-17.2.1-linux-x64"
    sha256 = "ec83d02c86101dea7493e61c38bf2cb9b7764f1c54c6f8d2bcf1e02df98dd172"
  }
  harness = {
    npm_package = "@anthropic-ai/claude-code"
    version     = "2.1.319"
  }
  bridge = {
    repository = "https://github.com/AgentWorkforce/relay.git"
    commit     = "7bf8a2bc3a13eb5708eab5207c2ed047fd953a44"
  }
  repositories = ["AgentWorkforce/relay-chief"]
}

run "host_is_private_and_reached_only_through_ssm" {
  command = plan

  assert {
    condition     = length(aws_security_group.this.ingress) == 0
    error_message = "The node must accept no inbound traffic."
  }
  assert {
    condition     = aws_instance.this.associate_public_ip_address == false
    error_message = "The node must have no public address."
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required with a hop limit of 1."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted
    error_message = "The root volume must be encrypted."
  }
}

run "role_reads_the_two_node_secrets_only" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role_policy.worker_token.policy).Statement[0].Resource == [aws_secretsmanager_secret.worker_token.arn, aws_secretsmanager_secret.harness_key.arn]
    error_message = "The role may read the node's two secrets and nothing else."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.worker_token.policy).Statement[1].Condition.StringEquals["kms:EncryptionContext:SecretARN"] == [aws_secretsmanager_secret.worker_token.arn, aws_secretsmanager_secret.harness_key.arn]
    error_message = "Decrypt must be limited to these secrets' encryption context."
  }
}

run "worker_token_stays_out_of_the_node_unit" {
  command = plan

  assert {
    condition     = !strcontains(file("${path.module}/files/chief-node.service"), "CHIEF_BRIDGE_RELAY_TOKEN") && !strcontains(file("${path.module}/files/chief-node.service"), "relay-token.env")
    error_message = "Spawned harnesses copy the node's environment: the token must never reach its unit."
  }
  assert {
    condition     = strcontains(file("${path.module}/files/chief-node.service"), "EnvironmentFile=-/run/chief-node-secrets/harness.env") && strcontains(file("${path.module}/files/chief-node.service"), "ExecStartPre=+/usr/local/sbin/chief-node-fetch-harness-key")
    error_message = "The harness key must reach the node by a root-run step, and the node must start without one."
  }
  assert {
    condition     = !strcontains(file("${path.module}/files/chief-bridge.service"), "harness.env")
    error_message = "The harness key has no business in the bridge."
  }
  assert {
    condition     = strcontains(file("${path.module}/files/chief-bridge.service"), "ExecStartPre=+/usr/local/sbin/chief-bridge-fetch-token")
    error_message = "The token must be fetched by a root-run step."
  }
  assert {
    condition     = strcontains(file("${path.module}/files/chief-node-metadata-block.service"), "--uid-owner chief-node -j DROP")
    error_message = "Instance metadata must be blocked for the service user."
  }
}

run "public_subnet_is_refused" {
  command = plan

  override_data {
    target = data.aws_subnet.this
    values = { vpc_id = "vpc-12345678", map_public_ip_on_launch = true }
  }

  expect_failures = [aws_instance.this]
}
