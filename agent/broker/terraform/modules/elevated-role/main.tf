# The role the broker vends APPROVAL-TIER sessions on in one account: every
# session on it needs Khaliq's own approval (broker/src/policy.ts, approval
# tier; verified as the human khaliq-gant through Relay). The session policy
# is exactly the approved actions on the approved resources; this file is the
# ceiling that holds regardless:
#  - trusted only by the broker role, and only with the broker's request id,
#    run, namespace and agent session tags plus a source identity (CloudTrail
#    names the agent and the request);
#  - PowerUserAccess minus every IAM, identity, organization, account, audit,
#    STS and key-policy control, so no approved session can grant itself
#    more, hide its tracks or touch identities;
#  - no change to the broker's audit log group (/aws-cred-broker/*);
#  - only the allowed regions.
# Unlike the sandbox's scoped role there are no run-tag denies: approved
# sessions act on the existing, untagged resources Khaliq named.
#
# Trust boundary: the broker runs on the layered-infra-ops host, whose
# instance role can assume the broker role, so a role here is also reachable
# by that host's lead without approval. Use this module only in accounts where
# that host already has administrator access (DESIGN.md).

locals {
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
          "kms:ScheduleKeyDeletion", "kms:PutKeyPolicy", "kms:CreateGrant",
        ]
        Resource = "*"
      },
      {
        # The broker's own audit log (modules/audit-log): no vended session may
        # write, delete, re-key, re-tag or shorten it. Reading stays allowed.
        Sid    = "DenyBrokerAuditLog"
        Effect = "Deny"
        Action = [
          "logs:DeleteLogGroup", "logs:DeleteLogStream", "logs:CreateLogStream", "logs:PutLogEvents",
          "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:AssociateKmsKey", "logs:DisassociateKmsKey",
          "logs:PutDataProtectionPolicy", "logs:DeleteDataProtectionPolicy", "logs:TagResource", "logs:UntagResource",
          "logs:TagLogGroup", "logs:UntagLogGroup", "logs:PutSubscriptionFilter", "logs:DeleteSubscriptionFilter",
        ]
        Resource = ["arn:aws:logs:*:*:log-group:/aws-cred-broker/*"]
      },
      {
        Sid       = "DenySessionsWithoutBrokerTags"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { Null = { "aws:PrincipalTag/broker-request-id" = "true" } }
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

resource "aws_iam_role" "elevated" {
  name                 = var.name
  description          = "Approval-tier agent sessions vended by the AWS credential broker, each approved by Khaliq. No IAM."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_iam_role_policy_attachment" "base" {
  role       = aws_iam_role.elevated.name
  policy_arn = var.base_policy_arn
}

resource "aws_iam_role_policy" "ceiling" {
  name   = "broker-ceiling"
  role   = aws_iam_role.elevated.id
  policy = jsonencode(local.ceiling_policy)
}
