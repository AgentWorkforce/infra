mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/terraform-apply/session" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/actors-control-plane" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::111111111111:role/terraform-apply" }
  }
  mock_data "aws_availability_zone" {
    defaults = { name = "us-west-2b" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      id     = "actors-regional"
      arn    = "arn:aws:s3:::actors-regional"
      region = "us-west-2"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/actors-actor-storage" }
  }
}

variables {
  name                    = "actors"
  express_az_id           = "usw2-az1"
  checkpoint_bucket_name  = "actors-regional"
  control_plane_role_name = "actors-control-plane"
  deployer_role_names     = ["relaycast-deployer"]
}

run "express_bucket_is_single_zone_in_the_requested_az" {
  command = apply

  assert {
    condition     = aws_s3_directory_bucket.express.bucket == "actors--usw2-az1--x-s3"
    error_message = "Directory bucket name must embed the AZ ID."
  }
  assert {
    condition     = one(aws_s3_directory_bucket.express.location).name == "usw2-az1" && aws_s3_directory_bucket.express.data_redundancy == "SingleAvailabilityZone"
    error_message = "The directory bucket must sit in express_az_id."
  }
  assert {
    condition     = output.express_bucket_arn == "arn:aws:s3express:us-west-2:111111111111:bucket/actors--usw2-az1--x-s3"
    error_message = "Unexpected s3express ARN."
  }
  assert {
    condition     = output.durable_actors_values.storage.artifactBucket == "actors-regional" && output.durable_actors_values.storage.s3.checkpoint.bucket == "actors-regional"
    error_message = "Artifacts and the checkpoint must live on the regional bucket."
  }
}

run "usw2_az2_has_no_express" {
  command = plan
  variables {
    express_az_id = "usw2-az2"
  }
  expect_failures = [aws_s3_directory_bucket.express]
}

run "zone_names_are_rejected" {
  command = plan
  variables {
    express_az_id = "us-west-2b"
  }
  expect_failures = [var.express_az_id]
}

run "checkpoint_must_be_regional" {
  command = plan
  variables {
    checkpoint_bucket_name = "copy--usw2-az3--x-s3"
  }
  expect_failures = [var.checkpoint_bucket_name]
}

run "express_grants_are_create_session_on_one_bucket_only" {
  command = apply

  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.actor.policy, aws_iam_role_policy.control_plane.policy] : alltrue([
        for s in jsondecode(policy).Statement :
        (s.Action == "s3express:CreateSession") == (s.Resource == output.express_bucket_arn)
      ])
    ])
    error_message = "Express must be reachable only through CreateSession on the one directory bucket ARN."
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.actor.policy).Statement :
      !contains(flatten([s.Action]), "s3:*") && !contains(flatten([s.Action]), "s3:DeleteObject")
    ])
    error_message = "The actor role must not delete or hold wildcard S3 actions."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.actor.policy).Statement :
      s.Sid == "CheckpointSnapshotsCreateOnly" && s.Condition.StringEquals["s3:if-none-match"] == "*"
    ])
    error_message = "Snapshot copies must be create-only."
  }
}

run "actor_role_is_assumable_only_by_the_control_plane" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role.actor.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:role/actors-control-plane" &&
      length(jsondecode(aws_iam_role.actor.assume_role_policy).Statement) == 1
    )
    error_message = "Only the control-plane role may assume the actor role."
  }
  assert {
    condition = contains(
      jsondecode(aws_s3_bucket_policy.express.policy).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"],
      "arn:aws:iam::111111111111:role/actors-actor-storage",
    )
    error_message = "The directory bucket policy must admit the actor role."
  }
  assert {
    condition = contains(
      jsondecode(aws_s3_bucket_policy.express.policy).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"],
      "arn:aws:iam::111111111111:role/terraform-apply",
    )
    error_message = "The directory bucket policy must admit the role applying the module, or later plans cannot read the bucket."
  }
}

run "deployers_never_touch_express" {
  command = apply

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.deployer["relaycast-deployer"].policy).Statement :
      !startswith(s.Action, "s3express:")
    ])
    error_message = "Deployers upload to the regional bucket only."
  }
}
