mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:us-west-2:111111111111:relay-session-events"
      url = "https://sqs.us-west-2.amazonaws.com/111111111111/relay-session-events"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/relay-session-pipeline" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:/aws/lambda/relay-session-pipeline" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:relay/session-pipeline-abc" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-west-2:111111111111:function:relay-session-pipeline" }
  }
  mock_data "aws_lambda_function" {
    defaults = {
      arn  = "arn:aws:lambda:us-west-2:111111111111:function:96bulls-test-session-pipeline"
      role = "arn:aws:iam::111111111111:role/96bulls-test-session-pipeline"
    }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-west-2:111111111111:rule/relay-session-reconcile" }
  }
}

variables {
  name        = "relay"
  bucket_name = "relay-sessions"
  package     = { s3_bucket = "relay-artifacts", s3_key = "session-pipeline.zip" }
}

run "hosted_pattern_defaults" {
  command = apply

  assert {
    condition     = length(aws_iam_role.this) == 1 && length(aws_iam_role_policy.this) == 1 && aws_lambda_function.this[0].role == aws_iam_role.this[0].arn && output.execution_role_arn == aws_lambda_function.this[0].role
    error_message = "The default must still author one role/policy and bind Lambda and its output to it."
  }

  # A distinct DLQ ARN, so the redrive assert checks the target's identity.
  override_resource {
    target = aws_sqs_queue.dlq
    values = {
      arn = "arn:aws:sqs:us-west-2:111111111111:relay-session-events-dlq"
      url = "https://sqs.us-west-2.amazonaws.com/111111111111/relay-session-events-dlq"
    }
  }

  assert {
    condition     = aws_sqs_queue.events.visibility_timeout_seconds == 6 * aws_lambda_function.this[0].timeout + aws_lambda_event_source_mapping.events.maximum_batching_window_in_seconds
    error_message = "Visibility timeout is six times the function timeout plus the batching window."
  }
  assert {
    condition     = jsondecode(aws_sqs_queue.events.redrive_policy).maxReceiveCount == 8 && jsondecode(aws_sqs_queue.events.redrive_policy).deadLetterTargetArn == "arn:aws:sqs:us-west-2:111111111111:relay-session-events-dlq"
    error_message = "Messages move to the DLQ after 8 receives."
  }
  assert {
    condition     = aws_sqs_queue.dlq.message_retention_seconds == 1209600
    error_message = "The DLQ keeps messages 14 days."
  }
  assert {
    condition     = aws_sqs_queue.events.sqs_managed_sse_enabled && aws_sqs_queue.dlq.sqs_managed_sse_enabled
    error_message = "Queues are encrypted."
  }
  assert {
    condition     = aws_lambda_event_source_mapping.events.batch_size == 10 && contains(aws_lambda_event_source_mapping.events.function_response_types, "ReportBatchItemFailures")
    error_message = "Batch 10 with partial batch failures."
  }
  assert {
    condition     = one(aws_s3_bucket_notification.manifests[0].queue).filter_suffix == "/manifest.json" && one(aws_s3_bucket_notification.manifests[0].queue).filter_prefix == "96bulls/"
    error_message = "Only manifest.json objects under 96bulls/ are notified."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.brief.state == "DISABLED" && aws_cloudwatch_event_rule.reconcile.state == "ENABLED"
    error_message = "Reconcile on, briefs off by default."
  }
  assert {
    condition     = aws_lambda_function.this[0].environment[0].variables.PIPELINE_RECONCILE_LOOKBACK_MINUTES == "60" && aws_lambda_function.this[0].environment[0].variables.SEARCH_INDEX_ENABLED == "0"
    error_message = "Lookback is twice the reconcile cadence; search index off by default."
  }
  assert {
    condition     = alltrue([for p in [aws_lambda_permission.reconcile[0], aws_lambda_permission.brief[0]] : p.principal == "events.amazonaws.com" && p.source_arn != null])
    error_message = "Only EventBridge rules (by ARN) may invoke the function; there is no Function URL."
  }
  assert {
    condition     = flatten([for s in jsondecode(aws_iam_role_policy.this[0].policy).Statement : s.Resource if s.Sid == "ReadSessionObjects"]) == ["arn:aws:s3:::relay-sessions/96bulls/*/v1/*"]
    error_message = "The role reads only session objects."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.this[0].policy).Statement : s if contains(flatten([s.Action]), "s3:PutObject") || contains(flatten([s.Action]), "s3:DeleteObject")]) == 0
    error_message = "The role never writes or deletes objects."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.this[0].policy).Statement : s if s.Sid == "VpcNetworkInterfaces"]) == 0
    error_message = "No ENI permissions outside a VPC."
  }
  assert {
    condition     = alltrue([for a in [aws_cloudwatch_metric_alarm.dlq_not_empty[0], aws_cloudwatch_metric_alarm.backlog_age[0], aws_cloudwatch_metric_alarm.errors[0]] : a.actions_enabled == false])
    error_message = "Alarms exist with actions disabled when no alarm_actions are given."
  }
}

run "briefs_enabled" {
  command = plan

  variables {
    briefs_enabled = true
  }

  assert {
    condition     = aws_cloudwatch_event_rule.brief.state == "ENABLED"
    error_message = "briefs_enabled turns the brief schedule on."
  }
}

run "bootstrap_disables_every_automatic_trigger" {
  command = plan
  variables {
    enabled        = false
    briefs_enabled = true
  }
  assert {
    condition     = !aws_lambda_event_source_mapping.events.enabled && aws_cloudwatch_event_rule.reconcile.state == "DISABLED" && aws_cloudwatch_event_rule.brief.state == "DISABLED" && !output.activation_enabled
    error_message = "Bootstrap must disable the queue mapping and both schedules, even when briefs are configured."
  }
}

run "exactly_one_package" {
  command = plan

  variables {
    package = { s3_bucket = "relay-artifacts", s3_key = "x.zip", image_uri = "111111111111.dkr.ecr.us-west-2.amazonaws.com/p:1" }
  }

  expect_failures = [var.package]
}

run "vpc_needs_security_groups" {
  command = plan

  variables {
    vpc_subnet_ids = ["subnet-a"]
  }

  expect_failures = [aws_lambda_function.this]
}

run "bucket_key_encryption_context" {
  command = plan

  variables {
    bucket_kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/abc"
  }

  assert {
    condition     = contains(one([for s in jsondecode(aws_iam_role_policy.this[0].policy).Statement : s.Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] if s.Sid == "DecryptSessionObjectsViaS3"]), "arn:aws:s3:::relay-sessions")
    error_message = "Decrypt must accept the bucket ARN context (S3 Bucket Keys)."
  }
}

run "image_must_be_digest_pinned" {
  command = plan

  variables {
    package = { image_uri = "111111111111.dkr.ecr.us-west-2.amazonaws.com/pipeline:latest" }
  }

  expect_failures = [var.package]
}

run "existing_role_authors_no_iam_and_binds_lambda" {
  command = apply
  variables {
    existing_execution_role_arn  = "arn:aws:iam::111111111111:role/bootstrap/pipeline-runtime"
    vpc_subnet_ids               = ["subnet-private"]
    vpc_security_group_ids       = ["sg-private"]
    additional_policy_statements = [{ Effect = "Allow", Action = ["es:ESHttpPost"], Resource = ["arn:aws:es:us-west-2:111111111111:domain/relay-search/*"] }]
  }
  assert {
    condition     = length(aws_iam_role.this) == 0 && length(aws_iam_role_policy.this) == 0
    error_message = "Existing-role mode must not author any IAM role or inline policy."
  }
  assert {
    condition     = aws_lambda_function.this[0].role == var.existing_execution_role_arn && output.execution_role_arn == aws_lambda_function.this[0].role
    error_message = "The actual Lambda role and exported role must both be the supplied identity."
  }
  assert {
    condition     = toset([for s in jsondecode(output.execution_role_policy_json).Statement : try(s.Sid, "Additional")]) == toset(["Logs", "ListBucket", "ReadSessionObjects", "SessionEvents", "PipelineSecret", "ReconcileContinues", "VpcNetworkInterfaces", "Additional"])
    error_message = "External mode must retain the proposed service permissions, including VPC and caller additions."
  }
}

run "existing_role_wrong_account_refused" {
  command = plan
  variables { existing_execution_role_arn = "arn:aws:iam::222222222222:role/pipeline" }
  expect_failures = [aws_lambda_function.this]
}

run "existing_role_wrong_partition_refused" {
  command = plan
  variables { existing_execution_role_arn = "arn:aws-us-gov:iam::111111111111:role/pipeline" }
  expect_failures = [aws_lambda_function.this]
}

run "existing_role_must_be_exact_role_arn" {
  command = plan
  variables { existing_execution_role_arn = "arn:aws:iam::111111111111:role/*" }
  expect_failures = [var.existing_execution_role_arn]
}

run "visibility_timeout_override" {
  command = plan
  variables { visibility_timeout_seconds = 1800 }

  assert {
    condition     = aws_sqs_queue.events.visibility_timeout_seconds == 1800
    error_message = "An explicit visibility_timeout_seconds replaces the computed default."
  }
}

run "visibility_timeout_below_function_timeout_refused" {
  command = plan
  variables { visibility_timeout_seconds = 299 }
  expect_failures = [aws_sqs_queue.events]
}

# Adopting an existing runtime (an import): only the queues, mapping and schedules are authored here.
run "adopt_existing_function" {
  command = plan
  variables {
    name                        = "96bulls-test"
    existing_function_name      = "96bulls-test-session-pipeline"
    visibility_timeout_seconds  = 1800
    max_concurrency             = 25
    brief_schedule_enabled      = true
    briefs_enabled              = false
    manage_queue_policies       = false
    manage_schedule_permissions = false
    create_alarms               = false
  }
  assert {
    condition     = length(aws_lambda_function.this) == 0 && length(aws_iam_role.this) == 0 && length(aws_iam_role_policy.this) == 0 && length(aws_cloudwatch_log_group.this) == 0 && length(aws_secretsmanager_secret.pipeline) == 0 && length(aws_lambda_function_event_invoke_config.this) == 0
    error_message = "An adopted function's role, log group, secret and invoke config are not authored here."
  }
  assert {
    condition     = length(aws_sqs_queue_policy.events) == 0 && length(aws_sqs_queue_policy.dlq) == 0 && length(aws_lambda_permission.brief) == 0 && length(aws_lambda_permission.reconcile) == 0 && length(aws_cloudwatch_metric_alarm.errors) == 0
    error_message = "Queue policies, permissions and alarms are off when not managed."
  }
  assert {
    condition     = aws_lambda_event_source_mapping.events.function_name == "arn:aws:lambda:us-west-2:111111111111:function:96bulls-test-session-pipeline" && one(aws_lambda_event_source_mapping.events.scaling_config).maximum_concurrency == 25
    error_message = "The mapping targets the adopted function at the input concurrency."
  }
  assert {
    condition     = aws_cloudwatch_event_target.brief.arn == "arn:aws:lambda:us-west-2:111111111111:function:96bulls-test-session-pipeline" && aws_cloudwatch_event_rule.brief.name == "96bulls-test-session-brief"
    error_message = "The brief schedule keeps the 96bulls-<stage> name and targets the adopted function."
  }
  assert {
    condition     = aws_sqs_queue.events.visibility_timeout_seconds == 1800 && aws_sqs_queue.events.name == "96bulls-test-session-events"
    error_message = "visibility_timeout_seconds overrides the computed value."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.brief.state == "ENABLED"
    error_message = "brief_schedule_enabled sets the state regardless of briefs_enabled."
  }
  assert {
    condition     = output.function_arn == "arn:aws:lambda:us-west-2:111111111111:function:96bulls-test-session-pipeline" && output.execution_role_arn == "arn:aws:iam::111111111111:role/96bulls-test-session-pipeline"
    error_message = "Outputs report the adopted function and its own role."
  }
}

run "adopt_without_package" {
  command = plan
  variables {
    package                     = null
    existing_function_name      = "relay-session-pipeline"
    manage_schedule_permissions = false
    create_alarms               = false
  }
  assert {
    condition     = length(aws_lambda_function.this) == 0
    error_message = "Adopt mode needs no package."
  }
}

run "package_required_without_adopt" {
  command         = plan
  variables { package = null }
  expect_failures = [aws_lambda_function.this]
}

run "schedule_description_prefix" {
  command = plan
  variables { schedule_description_prefix = "96bulls session pipeline" }
  assert {
    condition     = aws_cloudwatch_event_rule.reconcile.description == "96bulls session pipeline: reconcile recent manifests (lost notifications)" && aws_cloudwatch_event_rule.brief.description == "96bulls session pipeline: one session-brief tick (due wakeups)"
    error_message = "The prefix replaces only the product name in both rule descriptions."
  }
}

run "explicit_brief_disabled" {
  command = plan
  variables {
    briefs_enabled         = true
    brief_schedule_enabled = false
  }
  assert {
    condition     = aws_cloudwatch_event_rule.brief.state == "DISABLED"
    error_message = "brief_schedule_enabled = false disables the schedule."
  }
}

run "visibility_timeout_bounds" {
  command = plan
  variables {
    visibility_timeout_seconds = 43201
  }
  expect_failures = [var.visibility_timeout_seconds]
}
