# Read-only access to the dev EKS cluster for agents, through the credential
# broker (broker/allowlist.json: account label agentrelay-dev, workspaceAuto
# capability dev-cluster-read). Applied BY HAND by the dev account's owner,
# never from CI and never by an agent. See README.md and ../../DESIGN.md.
#
# One role, assumed only by the broker (same trust as modules/elevated-role:
# the broker's request id, run, namespace and agent session tags and a source
# identity, so CloudTrail names the agent and the request). Two layers, both
# read-only:
#  - AWS: the role's only permission is eks:DescribeCluster on this one
#    cluster, which is what `aws eks update-kubeconfig` calls. (`aws eks
#    get-token` needs no permission: it presigns sts:GetCallerIdentity.)
#  - Kubernetes: an EKS access entry for the role, associated with the
#    AWS-managed AmazonEKSViewPolicy at cluster scope. That maps to the
#    Kubernetes "view" role: workloads, jobs, pods and their logs, but no
#    Secrets and no write of any kind. No Kubernetes groups, no other policy.
#
# The cluster itself is not created or changed here. Its authentication mode
# must include API (API or API_AND_CONFIG_MAP): the plan stops otherwise.

provider "aws" {
  region              = var.region
  profile             = var.profile
  allowed_account_ids = [var.dev_account_id]

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "dev-account-owner-cred-broker-tf"
    }
  }
}

# Fails the plan, rather than the apply, when the cluster can't take access entries.
data "aws_eks_cluster" "this" {
  name = var.cluster_name

  lifecycle {
    postcondition {
      condition     = contains(["API", "API_AND_CONFIG_MAP"], one(self.access_config).authentication_mode)
      error_message = "Cluster ${var.cluster_name} must have authentication mode API or API_AND_CONFIG_MAP before access entries work. Changing it is the cluster owner's call (it can't be reverted to CONFIG_MAP)."
    }
  }
}

locals {
  cluster_arn = "arn:aws:eks:${var.region}:${var.dev_account_id}:cluster/${var.cluster_name}"
  # Must stay the AWS-managed read-only policy: the test pins it.
  view_policy_arn  = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  session_tag_keys = ["broker-request-id", var.tag_key, "agent-ns", "agent"]

  # Same shape as modules/elevated-role and modules/scoped-role.
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

  permissions_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DescribeTheDevCluster"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = [local.cluster_arn]
    }]
  }
}

resource "aws_iam_role" "read" {
  name                 = var.role_name
  description          = "Read-only dev EKS cluster sessions vended by the AWS credential broker (workspace agents, no approval)."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_iam_role_policy" "read" {
  name   = "describe-dev-cluster"
  role   = aws_iam_role.read.id
  policy = jsonencode(local.permissions_policy)
}

# The role is a Kubernetes principal on the cluster, with the view policy only.
resource "aws_eks_access_entry" "read" {
  cluster_name  = data.aws_eks_cluster.this.name
  principal_arn = aws_iam_role.read.arn
  type          = "STANDARD"
  tags          = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_eks_access_policy_association" "view" {
  cluster_name  = data.aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.read.principal_arn
  policy_arn    = local.view_policy_arn

  access_scope {
    type = "cluster"
  }
}
