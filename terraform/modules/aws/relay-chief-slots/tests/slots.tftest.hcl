mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-west-2"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-west-2a"
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0fedcba9876543210"
    }
  }
}

# aws_ebs_volume.data has prevent_destroy, which the test framework's teardown
# cannot clear, so every run plans. The rendered bootstrap depends on the
# volume id and is therefore unknown here; tests/test_slot_scripts.py checks
# its template instead.
variables {
  slot_ids    = ["slot-aaaa1111", "slot-bbbb2222"]
  vpc_id      = "vpc-12345678"
  subnet_id   = "subnet-12345678"
  kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/abc"
  ami_id      = "ami-0123456789abcdef0"
  node_runtime = {
    url    = "https://nodejs.example/node-linux-arm64.tar.xz"
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  }
  tags = { environment = "test" }
}

run "hosts_are_private_arm64_and_imdsv2_only" {
  command = plan

  assert {
    condition     = length(aws_instance.slot) == 2
    error_message = "One host per slot id."
  }
  assert {
    condition     = alltrue([for i in aws_instance.slot : i.instance_type == "t4g.small"])
    error_message = "Hosts default to t4g.small."
  }
  assert {
    condition     = alltrue([for i in aws_instance.slot : i.associate_public_ip_address == false])
    error_message = "Hosts must have no public IP."
  }
  assert {
    condition     = alltrue([for i in aws_instance.slot : one(i.metadata_options).http_tokens == "required" && one(i.metadata_options).http_put_response_hop_limit == 1])
    error_message = "IMDSv2 must be required, with a hop limit of 1."
  }
  assert {
    condition     = alltrue([for k, i in aws_instance.slot : i.tags["relay:chief-slot"] == k])
    error_message = "Each host must carry its own opaque slot tag."
  }
}

run "slot_tag_cannot_be_overridden" {
  command = plan

  variables {
    tags = { "relay:chief-slot" = "something-else" }
  }

  assert {
    condition     = alltrue([for k, i in aws_instance.slot : i.tags["relay:chief-slot"] == k])
    error_message = "tags must not override the per-slot tag."
  }
}

run "volumes_are_encrypted_and_separate" {
  command = plan

  assert {
    condition     = alltrue([for i in aws_instance.slot : one(i.root_block_device).encrypted == true && one(i.root_block_device).kms_key_id == "arn:aws:kms:us-west-2:111111111111:key/abc"])
    error_message = "The root volume must be encrypted with the customer managed key."
  }
  assert {
    condition     = length(aws_ebs_volume.data) == 2 && alltrue([for v in aws_ebs_volume.data : v.encrypted == true && v.kms_key_id == "arn:aws:kms:us-west-2:111111111111:key/abc"])
    error_message = "Each slot needs its own encrypted data volume."
  }
  assert {
    condition     = alltrue([for v in aws_ebs_volume.data : v.availability_zone == "us-west-2a"])
    error_message = "A data volume must be in the host's availability zone."
  }
  assert {
    condition     = alltrue([for a in aws_volume_attachment.data : a.stop_instance_before_detaching == true])
    error_message = "A live ledger must not be detached from a running host."
  }
}

run "security_group_has_no_ingress" {
  command = plan

  assert {
    condition     = length(aws_security_group.slots.ingress) == 0
    error_message = "The security group must have zero ingress rules."
  }
  assert {
    condition     = alltrue([for e in aws_security_group.slots.egress : e.from_port == 443 && e.to_port == 443 && e.protocol == "tcp"])
    error_message = "Egress is HTTPS only."
  }
}

run "roles_read_only_their_own_slot_secret" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role_policy.slot_secret["slot-aaaa1111"].policy).Statement[0].Resource == ["arn:aws:secretsmanager:us-west-2:111111111111:secret:relay-chief/slots/slot-aaaa1111-??????"]
    error_message = "A slot role must read only its own secret."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.slot_secret["slot-bbbb2222"].policy).Statement[0].Resource == ["arn:aws:secretsmanager:us-west-2:111111111111:secret:relay-chief/slots/slot-bbbb2222-??????"]
    error_message = "A slot role must read only its own secret."
  }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.slot_secret : jsondecode(p.policy).Statement[0].Action == ["secretsmanager:GetSecretValue"]])
    error_message = "Secret access is read-only."
  }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.slot_secret : alltrue([for s in jsondecode(p.policy).Statement : !contains(flatten([s.Resource]), "*")])])
    error_message = "A slot policy must not grant Resource \"*\"."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.slot_secret["slot-aaaa1111"].policy).Statement[1].Condition.StringLike["kms:EncryptionContext:SecretARN"] == "arn:aws:secretsmanager:us-west-2:111111111111:secret:relay-chief/slots/slot-aaaa1111-??????"
    error_message = "KMS decrypt must be limited to the slot's own secret."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.slot_secret["slot-aaaa1111"].policy).Statement[1].Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-west-2.amazonaws.com"
    error_message = "KMS decrypt must be limited to Secrets Manager."
  }
  assert {
    condition     = alltrue([for a in aws_iam_role_policy_attachment.ssm : a.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"])
    error_message = "Every role needs the SSM managed policy."
  }
  assert {
    condition     = alltrue([for k, p in aws_iam_instance_profile.slot : p.name == "relay-chief-${k}"])
    error_message = "Each host has its own instance profile."
  }
}

run "host_files_are_the_expected_set" {
  command = plan

  assert {
    condition     = toset([for f in local.host_files : f.path]) == toset(["/etc/systemd/system/relay-chief.service", "/etc/systemd/system/relay-chief.timer", "/etc/systemd/system/relay-chief.service.d/10-slot.conf", "/etc/systemd/system/relay-chief-credentials.service", "/usr/local/sbin/relay-chief-fetch-credentials", "/usr/local/sbin/relay-chief-bind-slot", "/usr/local/sbin/relay-chief-fetch-artifact", "/usr/local/sbin/relay-chief-prepare-data-volume"])
    error_message = "Bootstrap must install exactly the reference units, the drop-in, the credentials unit and the four scripts."
  }
  assert {
    condition     = alltrue([for f in local.host_files : length(f.content) > 0])
    error_message = "Every host file must have content."
  }
}

run "output_maps_slots_to_instances" {
  command = plan

  assert {
    condition     = keys(output.slots) == ["slot-aaaa1111", "slot-bbbb2222"]
    error_message = "The slots output is keyed by slot id."
  }
  assert {
    condition     = output.slots["slot-aaaa1111"].secret_name == "relay-chief/slots/slot-aaaa1111"
    error_message = "The output records each slot's secret name."
  }
}

run "ami_from_ssm_parameter" {
  command = plan

  variables {
    ami_id            = null
    ami_ssm_parameter = "/example/arm64/ami"
  }

  assert {
    condition     = alltrue([for i in aws_instance.slot : i.ami == "ami-0fedcba9876543210"])
    error_message = "The AMI comes from the SSM parameter."
  }
}

run "exactly_one_ami_source_both" {
  command = plan

  variables {
    ami_ssm_parameter = "/example/arm64/ami"
  }

  expect_failures = [aws_instance.slot]
}

run "exactly_one_ami_source_neither" {
  command = plan

  variables {
    ami_id = null
  }

  expect_failures = [aws_instance.slot]
}

run "slot_id_format_is_validated" {
  command = plan

  variables {
    slot_ids = ["Customer Name"]
  }

  expect_failures = [var.slot_ids]
}

run "node_checksum_is_validated" {
  command = plan

  variables {
    node_runtime = { url = "https://nodejs.example/node.tar.xz", sha256 = "not-a-checksum" }
  }

  expect_failures = [var.node_runtime]
}

run "quote_in_node_url_is_refused" {
  command = plan

  variables {
    node_runtime = {
      url    = "https://nodejs.example/node'.tar.xz"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.node_runtime]
}

run "quote_in_artifact_url_is_refused" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "https://example.test/relay'chief.tar.gz"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.relay_chief_artifact]
}

run "s3_artifact_grants_only_that_object" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "s3://example-artifacts/relay-chief/build.tar.gz"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.artifact) == 2
    error_message = "Every slot role needs the artifact grant."
  }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.artifact : length(jsondecode(p.policy).Statement) == 1 && jsondecode(p.policy).Statement[0].Action == ["s3:GetObject"]])
    error_message = "The artifact grant is s3:GetObject alone."
  }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.artifact : jsondecode(p.policy).Statement[0].Resource == ["arn:aws:s3:::example-artifacts/relay-chief/build.tar.gz"]])
    error_message = "The artifact grant is limited to that exact object."
  }
  assert {
    condition     = alltrue([for k, p in aws_iam_role_policy.artifact : p.name == "read-relay-chief-artifact"])
    error_message = "The artifact grant is its own inline policy."
  }
}

run "https_artifact_grants_nothing" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "https://example.test/relay-chief.tar.gz"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.artifact) == 0
    error_message = "An https artifact needs no S3 access."
  }
}

run "no_artifact_grants_nothing" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.artifact) == 0
    error_message = "No artifact needs no S3 access."
  }
}

run "s3_uri_without_a_key_is_refused" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "s3://example-artifacts/"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.relay_chief_artifact]
}

run "s3_uri_with_an_iam_wildcard_is_refused" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "s3://example-artifacts/relay-chief/*"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.relay_chief_artifact]
}

run "s3_uri_with_a_quote_is_refused" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "s3://example-artifacts/relay'chief.tar.gz"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.relay_chief_artifact]
}

run "s3_artifact_checksum_is_validated" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "s3://example-artifacts/relay-chief.tar.gz"
      sha256 = "not-a-checksum"
    }
  }

  expect_failures = [var.relay_chief_artifact]
}

run "plain_http_artifact_is_refused" {
  command = plan

  variables {
    relay_chief_artifact = {
      url    = "http://example.test/relay-chief.tar.gz"
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.relay_chief_artifact]
}
