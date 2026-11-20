# Alerting scaffold for the exit tooling that runs on this box (the legacy
# erasure CLI writes one JSON line per event). The CloudWatch agent ships
# each file in var.runner_log_files under var.runner_log_dir to one log group
# (one collect entry per file: a wildcard would ship only the newest match);
# metric filters turn
# the fence signals (var.alert_signals) into metrics; one alarm per signal
# publishes to the ops SNS topic. Where the topic delivers is
# var.alert_endpoint: until it is set the topic has no subscription, so the
# alarms fire into nothing. Nothing here touches the instance's user_data, so
# adding it does not replace a running runner.

resource "aws_cloudwatch_log_group" "runner" {
  #checkov:skip=CKV_AWS_158:Counts and error codes only (no session content); AWS-managed encryption at rest.
  #checkov:skip=CKV_AWS_338:Short-lived runner; retention is var.log_retention_days.
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
  tags              = { Name = var.name }
}

resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:Notifications carry the alarm name and metric only; a CMK adds a cloudwatch.amazonaws.com key policy to get wrong for no data protection gain.
  name = "${var.name}-alerts"
  tags = { Name = "${var.name}-alerts" }
}

# The delivery leg. Absent until the operator names the endpoint.
resource "aws_sns_topic_subscription" "alerts" {
  count = var.alert_endpoint == null ? 0 : 1

  topic_arn              = aws_sns_topic.alerts.arn
  protocol               = var.alert_protocol
  endpoint               = var.alert_endpoint
  endpoint_auto_confirms = var.alert_protocol == "https"
}

# CloudWatch agent configuration, fetched by the agent on the runner through
# the instance role (ssm:GetParameter on this one parameter).
locals {
  cloudwatch_agent_config = jsonencode({
    agent = { region = var.region }
    logs = {
      logs_collected = {
        files = {
          # One entry per file: with a wildcard the agent ships only the
          # newest matching file, so older files would be skipped.
          collect_list = [for f in var.runner_log_files : {
            file_path       = "${var.runner_log_dir}/${f}"
            log_group_name  = aws_cloudwatch_log_group.runner.name
            log_stream_name = "{instance_id}/${trimsuffix(f, ".log")}"
            timezone        = "UTC"
          }]
        }
      }
    }
  })
}

resource "aws_ssm_parameter" "cloudwatch_agent" {
  #checkov:skip=CKV_AWS_337:The agent configuration names file paths and a log group; nothing secret.
  #checkov:skip=CKV2_AWS_34:The agent configuration names file paths and a log group; nothing secret.
  name        = "/${var.name}/cloudwatch-agent"
  description = "CloudWatch agent configuration for the Neon exit runner (log shipping only)"
  type        = "String"
  value       = local.cloudwatch_agent_config
  tags        = { Name = var.name }
}

data "aws_iam_policy_document" "log_shipping" {
  statement {
    sid       = "ShipRunnerLog"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [aws_cloudwatch_log_group.runner.arn, "${aws_cloudwatch_log_group.runner.arn}:*"]
  }

  statement {
    sid       = "ReadAgentConfig"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.cloudwatch_agent.arn]
  }
}

resource "aws_iam_role_policy" "log_shipping" {
  name   = "${var.name}-log-shipping"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.log_shipping.json
}

# Install and start the agent on the running instance through Systems
# Manager, so the instance is not replaced (user_data_replace_on_change).
# The hash of the agent configuration is part of the commands, so a changed
# configuration changes the association and runs it again (the agent only
# re-reads the parameter on fetch-config). A failed run is retried with
#   aws ssm start-associations-once --association-ids <id>
resource "aws_ssm_association" "cloudwatch_agent" {
  name             = "AWS-RunShellScript"
  association_name = "${var.name}-cloudwatch-agent"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.runner.id]
  }

  parameters = {
    commands = join("\n", [
      "set -euo pipefail",
      "# cloudwatch-agent config ${sha256(local.cloudwatch_agent_config)}",
      "id '${var.runner_log_owner}' >/dev/null 2>&1 || useradd -m '${var.runner_log_owner}'",
      "install -d -m 0750 -o '${var.runner_log_owner}' -g '${var.runner_log_owner}' '${var.runner_log_dir}'",
      "rpm -q amazon-cloudwatch-agent >/dev/null 2>&1 || dnf -y install amazon-cloudwatch-agent",
      "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c 'ssm:${aws_ssm_parameter.cloudwatch_agent.name}'",
    ])
  }

  depends_on = [aws_iam_role_policy.log_shipping]
}

resource "aws_cloudwatch_log_metric_filter" "signal" {
  for_each = var.alert_signals

  name           = each.key
  pattern        = each.value
  log_group_name = aws_cloudwatch_log_group.runner.name

  metric_transformation {
    name          = each.key
    namespace     = var.metric_namespace
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "signal" {
  for_each = var.alert_signals

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = "Neon exit runner logged ${each.key} (filter: ${each.value}); see the legacy erasure runbook before the legacy exporter stays active."
  namespace           = var.metric_namespace
  metric_name         = each.key
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = [aws_sns_topic.alerts.arn]
  # No ok_actions: the metric is a count of matching lines, so the alarm
  # returns to OK one minute after the last match. That is not "resolved";
  # whoever is paged closes the incident after the runbook.
  tags = { Name = "${var.name}-${each.key}" }
}

# Dead man: the eraser logs one "erasure sweep" summary line per sweep. When
# that line stops arriving (eraser down, agent down, log path wrong, or the
# privacy authority not ready, which writes no summary), the alarm pages.
# Missing data is breaching by design, so heartbeat_enabled is false until
# the apply that starts the eraser: created earlier it would sit in ALARM,
# and an alarm that never transitions never pages. Sweeps are 600 s or more
# apart (sweep and drain time push some summaries past one bucket), hence
# 2 breaching datapoints out of 3 rather than 2 of 2.
resource "aws_cloudwatch_log_metric_filter" "heartbeat" {
  count = var.heartbeat_enabled ? 1 : 0

  name           = "erasure_sweep"
  pattern        = var.heartbeat_pattern
  log_group_name = aws_cloudwatch_log_group.runner.name

  metric_transformation {
    name          = "erasure_sweep"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  count = var.heartbeat_enabled ? 1 : 0

  alarm_name          = "${var.name}-erasure-sweep-missing"
  alarm_description   = "No \"erasure sweep\" summary line from neon-s3-erasure on the Neon exit runner in ${var.heartbeat_datapoints_to_alarm} of the last ${var.heartbeat_evaluation_periods} x ${var.heartbeat_period_seconds} s: eraser, CloudWatch agent or log path is down, or the privacy authority is not ready."
  namespace           = var.metric_namespace
  metric_name         = "erasure_sweep"
  statistic           = "Sum"
  period              = var.heartbeat_period_seconds
  evaluation_periods  = var.heartbeat_evaluation_periods
  datapoints_to_alarm = var.heartbeat_datapoints_to_alarm
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  actions_enabled     = true
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn] # sweeps resumed: genuinely resolved
  tags                = { Name = "${var.name}-erasure-sweep-missing" }
}
