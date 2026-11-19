# The credential broker's role, in the layered-infra-ops host's account. Only
# the host role (exact ARN, via aws:PrincipalArn) may assume it, and it may do
# exactly two things: assume the listed target roles with session tags and a
# source identity, and (when audit_log_group_arn is set) append to the audit
# log group. It has no other permission, so a leaked broker session can mint
# sessions (bounded by the target roles) and add audit lines, and nothing else.

locals {
  trust_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid       = "BrokerHostOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = { ArnEquals = { "aws:PrincipalArn" = var.trusted_principal_arns } }
    }]
  }

  permissions_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "VendIntoTargetRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
        Resource = var.target_role_arns
      }],
      # Audit shipping (broker/src/ship.ts): create a stream in the audit group
      # and append to it. No read, delete, retention or policy change.
      var.audit_log_group_arn == null ? [] : [{
        Sid    = "ShipAuditLog"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        # CreateLogStream is checked against the group (ARN, or ARN:*), PutLogEvents against its streams.
        Resource = [var.audit_log_group_arn, "${var.audit_log_group_arn}:*"]
      }],
    )
  }
}

resource "aws_iam_role" "broker" {
  name                 = var.name
  description          = "AWS credential broker (layered-infra-ops): mints short-lived, request-scoped agent sessions."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_iam_role_policy" "vend" {
  name   = "vend-agent-sessions"
  role   = aws_iam_role.broker.id
  policy = jsonencode(local.permissions_policy)
}
