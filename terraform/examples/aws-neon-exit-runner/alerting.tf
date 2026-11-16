# Alerting scaffold for the exit tooling that runs on this box (the legacy
# erasure CLI writes one JSON line per event). The CloudWatch agent ships
# every *.log under var.runner_log_dir to one log group; metric filters turn
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
resource "aws_ssm_parameter" "cloudwatch_agent" {
  #checkov:skip=CKV_AWS_337:The agent configuration names a file glob and a log group; nothing secret.
  #checkov:skip=CKV2_AWS_34:The agent configuration names a file glob and a log group; nothing secret.
  name        = "/${var.name}/cloudwatch-agent"
  description = "CloudWatch agent configuration for the Neon exit runner (log shipping only)"
  type        = "String"
  value = jsonencode({
    agent = { region = var.region }
    logs = {
      logs_collected = {
        files = {
          collect_list = [{
            file_path       = "${var.runner_log_dir}/*.log"
            log_group_name  = aws_cloudwatch_log_group.runner.name
            log_stream_name = "{instance_id}"
            timezone        = "UTC"
          }]
        }
      }
    }
  })
  tags = { Name = var.name }
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
      "# cloudwatch-agent config ${sha256(aws_ssm_parameter.cloudwatch_agent.value)}",
      "install -d -m 1777 '${var.runner_log_dir}'",
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
    name      = each.key
    namespace = var.metric_namespace
    value     = "1"
    unit      = "Count"
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
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${var.name}-${each.key}" }
}
