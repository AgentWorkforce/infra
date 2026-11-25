# Read-only access to the session pipeline's indexing Lambda for agents,
# through the credential broker (broker/allowlist.json: account label
# sessions-prod). Applied by the owner himself with his own credentials in the
# sessions account, plan first; never from CI and never from a branch. The
# infra agent's roles have no access to that account. See README.md and
# ../../DESIGN.md.
#
# One role, assumed only by the broker (same trust as modules/elevated-role:
# the broker's request id, run, namespace and agent session tags and a source
# identity, so CloudTrail names the agent and the request). Its only
# permissions are two read-only statements:
#  - Lambda: the configuration, versions and aliases of the one function. No
#    lambda:GetFunction (that returns a download link for the code), no
#    invoke, no update.
#  - CloudWatch Logs: list and read the log streams of that function's one
#    log group. No Logs Insights (two of its three actions take no resource,
#    so they can't be limited to this group) and no other log group.
#
# The function and the log group are not created or changed here. Both must
# exist: the plan stops otherwise, so a typo can't produce a role that reads
# nothing.

provider "aws" {
  region              = var.region
  profile             = var.profile
  allowed_account_ids = [var.sessions_account_id]

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "infra-ops-cred-broker-sessions-tf"
    }
  }
}

# The list of function names only. Not data.aws_lambda_function: that would
# copy the function's environment variable values into this root's state.
data "aws_lambda_functions" "all" {
  lifecycle {
    postcondition {
      condition     = contains(self.function_names, var.function_name)
      error_message = "Function ${var.function_name} was not found in this account and region. Check function_name, region and the profile before applying."
    }
  }
}

# Fails the plan when the log group is missing.
data "aws_cloudwatch_log_group" "this" {
  name = local.log_group_name
}

locals {
  log_group_name = coalesce(var.log_group_name, "/aws/lambda/${var.function_name}")
  function_arn   = "arn:aws:lambda:${var.region}:${var.sessions_account_id}:function:${var.function_name}"
  log_group_arn  = "arn:aws:logs:${var.region}:${var.sessions_account_id}:log-group:${local.log_group_name}"

  session_tag_keys = ["broker-request-id", var.tag_key, "agent-ns", "agent"]

  trust_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "BrokerAssumesWithRequestTags"
        Effect    = "Allow"
        Principal = { AWS = var.broker_role_arn }
        Action    = "sts:AssumeRole"
        Condition = {
          StringLike = { "aws:RequestTag/broker-request-id" = "cb-*" }
          Null = {
            "aws:RequestTag/${var.tag_key}" = "false"
            "aws:RequestTag/agent-ns"       = "false"
            "aws:RequestTag/agent"          = "false"
            "sts:SourceIdentity"            = "false"
          }
        }
      },
      {
        Sid       = "BrokerTagsSessions"
        Effect    = "Allow"
        Principal = { AWS = var.broker_role_arn }
        Action    = "sts:TagSession"
        Condition = {
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.session_tag_keys }
          StringLike                  = { "aws:RequestTag/broker-request-id" = "cb-*" }
        }
      },
      {
        Sid       = "BrokerSetsSourceIdentity"
        Effect    = "Allow"
        Principal = { AWS = var.broker_role_arn }
        Action    = "sts:SetSourceIdentity"
        Condition = { StringLike = { "sts:SourceIdentity" = "?*" } }
      },
    ]
  }

  # The ":*" forms are part of the two resources, not a wider match: a
  # function's versions and aliases are "<function arn>:<qualifier>", and a
  # log group's streams are "<log group arn>:log-stream:<name>".
  permissions_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTheFunctionConfiguration"
        Effect   = "Allow"
        Action   = ["lambda:GetFunctionConfiguration", "lambda:ListVersionsByFunction", "lambda:ListAliases"]
        Resource = [local.function_arn, "${local.function_arn}:*"]
      },
      {
        Sid      = "ReadTheFunctionLogs"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"]
        Resource = [local.log_group_arn, "${local.log_group_arn}:*"]
      },
    ]
  }
}

resource "aws_iam_role" "read" {
  name                 = var.role_name
  description          = "Read-only: the session pipeline Lambda's configuration and its log group. Assumed only by the agent credential broker."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })

  # No role without the two checks above.
  depends_on = [data.aws_lambda_functions.all, data.aws_cloudwatch_log_group.this]
}

resource "aws_iam_role_policy" "read" {
  name   = "read-session-pipeline-lambda"
  role   = aws_iam_role.read.id
  policy = jsonencode(local.permissions_policy)
}
