# Rendering tests with a mocked AWS provider. They prove the shape this root plans; only a CI
# plan against the live account proves zero changes.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:111111111111:function:96bulls-test-session-pipeline" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/96bulls-test-session-pipeline" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:111111111111:96bulls-test-session-events-dlq" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:96bulls/test/session-pipeline-abcdef" }
  }
  mock_resource "aws_lambda_event_source_mapping" {
    defaults = { function_arn = "arn:aws:lambda:us-east-1:111111111111:function:96bulls-test-session-pipeline" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:111111111111:rule/96bulls-test-session-reconcile" }
  }
}

variables {
  import_existing = false
  account_id      = "111111111111"
  region          = "us-east-1"
  name_prefix     = "96bulls-test"
  function_name   = "96bulls-test-session-pipeline"
  bucket_name     = "test-transcripts"
  kms_key_id      = "00000000-0000-0000-0000-000000000000"
  secret_name     = "96bulls/test/session-pipeline"
  role = {
    name               = "96bulls-test-session-pipeline"
    assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    inline_policies    = { "session-pipeline" = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"*\"}]}" }
  }
  bucket_policy_other_statements = "[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":\"*\",\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}},{\"Sid\":\"IngestEdgeWrites\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::222222222222:role/ingest-edge\"},\"Action\":\"s3:PutObject\",\"Resource\":\"*\"}]"
  kms_policy_other_statements    = "[{\"Sid\":\"KeyAdmin\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111111111111:root\"},\"Action\":\"kms:*\",\"Resource\":\"*\"}]"
  max_concurrency                = 25
  import_ids = {
    event_source_mapping_uuid = "00000000-0000-0000-0000-000000000001"
    secret_arn                = "arn:aws:secretsmanager:us-east-1:111111111111:secret:96bulls/test/session-pipeline-abcdef"
    permission_statement_ids  = { reconcile = "r1", reconcile_continue = "c1", brief = "b1" }
  }
}

run "mirrors_the_old_stack" {
  command = apply

  assert {
    condition     = aws_sqs_queue.events.name == "96bulls-test-session-events" && aws_sqs_queue.events.visibility_timeout_seconds == 1800 && aws_sqs_queue.events.delay_seconds == 30 && aws_sqs_queue.events.receive_wait_time_seconds == 20 && aws_sqs_queue.events.message_retention_seconds == 345600
    error_message = "session-events keeps the old stack's settings (VT 1800, delay 30, wait 20, 4 days)."
  }
  assert {
    condition     = one(aws_lambda_event_source_mapping.events.scaling_config).maximum_concurrency == 25 && aws_lambda_event_source_mapping.events.batch_size == 10 && aws_lambda_event_source_mapping.events.maximum_batching_window_in_seconds == 20
    error_message = "The mapping takes the hosted concurrency and keeps batch 10 / 20 s."
  }
  assert {
    condition     = toset(keys(aws_cloudwatch_event_rule.schedule)) == toset(["reconcile", "brief"]) && aws_cloudwatch_event_rule.schedule["brief"].state == "DISABLED" && aws_cloudwatch_event_rule.schedule["reconcile"].state == "ENABLED"
    error_message = "Only the two live rules; briefs stay disabled by default."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.schedule["reconcile"].description == "96bulls session pipeline: reconcile recent manifests (lost notifications)" && aws_cloudwatch_event_target.schedule["reconcile"].input == "{\"reconcile\":true}"
    error_message = "Rule descriptions and tick bodies equal the old stack's."
  }
  assert {
    condition     = toset(keys(aws_lambda_permission.pipeline)) == toset(["reconcile", "brief", "reconcile_continue"]) && aws_lambda_permission.pipeline["reconcile_continue"].principal == "arn:aws:iam::111111111111:role/96bulls-test-session-pipeline"
    error_message = "Three grants, as live: two schedules and the role's self-invoke."
  }
  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.transcripts.policy).Statement) == 4 && contains([for s in jsondecode(aws_s3_bucket_policy.transcripts.policy).Statement : s.Sid], "IngestEdgeWrites")
    error_message = "The bucket policy is the pipeline's statements plus every private one, ingest-edge grants included."
  }
  assert {
    condition     = length(jsondecode(aws_kms_key_policy.transcripts.policy).Statement) == 2
    error_message = "The key policy is the pipeline's decrypt grant plus the private statements."
  }
  assert {
    condition     = one(aws_s3_bucket_notification.transcripts.queue).filter_prefix == "96bulls/" && one(aws_s3_bucket_notification.transcripts.queue).filter_suffix == "/manifest.json"
    error_message = "One notification: manifest puts and deletes under 96bulls/."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.errors.alarm_name == "96bulls-test-session-pipeline-errors" && !aws_cloudwatch_metric_alarm.errors.actions_enabled
    error_message = "Alarms keep their live names, actions disabled."
  }
}

run "optional_schedule_group" {
  command = apply
  variables {
    optional_schedules = { analysisCache = false }
    import_ids = {
      event_source_mapping_uuid = "00000000-0000-0000-0000-000000000001"
      secret_arn                = "arn:aws:secretsmanager:us-east-1:111111111111:secret:96bulls/test/session-pipeline-abcdef"
      permission_statement_ids  = { reconcile = "r1", reconcile_continue = "c1", brief = "b1", analysis_cache = "a1", analysis_reconcile = "a2" }
    }
  }
  assert {
    condition     = aws_cloudwatch_event_rule.schedule["analysis_reconcile"].name == "96bulls-test-session-reconcile-analysis-backfill" && aws_cloudwatch_event_rule.schedule["analysis_cache"].state == "DISABLED"
    error_message = "A declared group adds its rules under the old names."
  }
}

run "other_notifications_kept_verbatim" {
  command = apply
  variables {
    other_notifications = {
      queues = [{ id = "96bulls-upload-inbox", queue_arn = "arn:aws:sqs:us-east-1:111111111111:upload", events = ["s3:ObjectCreated:*"], filter_prefix = "inbox/" }]
    }
  }
  assert {
    condition     = length(aws_s3_bucket_notification.transcripts.queue) == 2 && !aws_s3_bucket_notification.transcripts.eventbridge
    error_message = "Every other live notification is carried alongside the pipeline's."
  }
}

run "duplicate_rendered_sid_refused" {
  command = plan
  variables {
    bucket_policy_other_statements = "[{\"Sid\":\"SessionPipelineReads\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"*\"}]"
  }
  expect_failures = [aws_s3_bucket_policy.transcripts]
}

run "missing_statement_id_refused" {
  command = plan
  variables {
    import_ids = {
      event_source_mapping_uuid = "00000000-0000-0000-0000-000000000001"
      secret_arn                = "arn:aws:secretsmanager:us-east-1:111111111111:secret:96bulls/test/session-pipeline-abcdef"
      permission_statement_ids  = { reconcile = "r1", brief = "b1" }
    }
  }
  expect_failures = [aws_lambda_permission.pipeline]
}
