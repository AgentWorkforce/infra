# The role the broker vends automatic (sandbox, own run tag) sessions on. The
# effective permissions of a session are this role's policies intersected
# with the broker's inline session policy; this file is the ceiling that holds
# even if the broker's policy engine is wrong:
#  - trusted only by the broker role, and only when the broker sets a request
#    id, run tag and agent session tag plus a source identity (so CloudTrail
#    names the agent and the request on every call);
#  - no IAM, identity, organization, account, audit or STS control;
#  - no session without the run tag; nothing created with another run's tag;
#    the run tag can't be removed, and can be added only at create time (EC2)
#    or on resources named for the run (other services' tag-on-create);
#  - deletes and stops only on resources tagged with the session's own run;
#  - only the allowed regions.

locals {
  session_tag_keys = ["broker-request-id", var.tag_key, "agent"]
  own_run          = "$${aws:PrincipalTag/${var.tag_key}}"

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

  # Tag writes that add a key: with the run tag, only on resources the run
  # owns by name (<run tag>-…), so tag-on-create works (CreateQueue also checks
  # sqs:TagQueue, and so on) but an existing resource can't be claimed.
  # Must match broker/src/policy.ts TAG_ACTIONS and ownNamedResources.
  tag_actions = [
    "sqs:TagQueue", "sns:TagResource", "logs:TagResource", "logs:TagLogGroup",
    "dynamodb:TagResource", "secretsmanager:TagResource",
  ]
  own_named_resources = [
    "arn:aws:sqs:*:*:${local.own_run}-*",
    "arn:aws:sns:*:*:${local.own_run}-*",
    "arn:aws:logs:*:*:log-group:${local.own_run}-*",
    "arn:aws:dynamodb:*:*:table/${local.own_run}-*",
    "arn:aws:secretsmanager:*:*:secret:${local.own_run}-*",
  ]
  # Removing the run tag, or tagging through the generic API: never with the run tag. Matches UNTAG_ACTIONS.
  untag_actions = [
    "ec2:DeleteTags", "tag:TagResources", "tag:UntagResources",
    "sqs:UntagQueue", "sns:UntagResource", "logs:UntagResource", "logs:UntagLogGroup",
    "dynamodb:UntagResource", "secretsmanager:UntagResource",
  ]

  # Stop and delete class actions the broker can grant automatically: only on the session's own run.
  own_run_only_actions = [
    "ec2:StopInstances", "ec2:TerminateInstances", "ec2:RebootInstances",
    "ec2:DetachVolume", "ec2:DeleteVolume",
    "sqs:DeleteQueue", "sqs:PurgeQueue", "sns:DeleteTopic", "logs:DeleteLogGroup",
    "dynamodb:DeleteTable", "secretsmanager:DeleteSecret",
  ]

  ceiling_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyIdentityAccountAndAuditControl"
        Effect = "Deny"
        Action = [
          "iam:*", "sts:*", "organizations:*", "account:*", "billing:*", "aws-portal:*",
          "sso:*", "sso-directory:*", "identitystore:*",
          "cloudtrail:*", "config:*", "guardduty:*", "securityhub:*", "ram:*",
          "kms:ScheduleKeyDeletion", "kms:PutKeyPolicy",
        ]
        Resource = "*"
      },
      {
        Sid       = "DenySessionsWithoutRunTag"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { Null = { "aws:PrincipalTag/${var.tag_key}" = "true" } }
      },
      {
        Sid      = "DenyCreatingWithAnotherRunsTag"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          StringNotEquals = { "aws:RequestTag/${var.tag_key}" = local.own_run }
          Null            = { "aws:RequestTag/${var.tag_key}" = "false" }
        }
      },
      {
        Sid       = "DenyRemovingTheRunTag"
        Effect    = "Deny"
        Action    = local.untag_actions
        Resource  = "*"
        Condition = { "ForAnyValue:StringEquals" = { "aws:TagKeys" = [var.tag_key] } }
      },
      {
        Sid         = "DenyRunTagOnResourcesNotNamedForTheRun"
        Effect      = "Deny"
        Action      = local.tag_actions
        NotResource = local.own_named_resources
        Condition   = { "ForAnyValue:StringEquals" = { "aws:TagKeys" = [var.tag_key] } }
      },
      {
        Sid       = "DenyEc2TagsAfterCreate"
        Effect    = "Deny"
        Action    = "ec2:CreateTags"
        Resource  = "*"
        Condition = { Null = { "ec2:CreateAction" = "true" } }
      },
      {
        Sid       = "DenyStopAndDeleteOutsideOwnRun"
        Effect    = "Deny"
        Action    = local.own_run_only_actions
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:ResourceTag/${var.tag_key}" = local.own_run } }
      },
      {
        Sid       = "DenyOutsideAllowedRegions"
        Effect    = "Deny"
        NotAction = ["iam:*", "sts:*", "cloudfront:*", "route53:*", "support:*", "budgets:*", "ce:*", "health:*", "s3:ListAllMyBuckets"]
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } }
      },
    ]
  }
}

resource "aws_iam_role" "scoped" {
  name                 = var.name
  description          = "Agent sessions vended by the AWS credential broker: own run tag only, no IAM."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_iam_role_policy_attachment" "base" {
  role       = aws_iam_role.scoped.name
  policy_arn = var.base_policy_arn
}

resource "aws_iam_role_policy" "ceiling" {
  name   = "broker-ceiling"
  role   = aws_iam_role.scoped.id
  policy = jsonencode(local.ceiling_policy)
}
