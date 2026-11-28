# Read-only access to the prod EKS cluster for agents, through the credential
# broker (broker/allowlist.json: account label agentrelay-prod, workspaceAuto
# capability prod-cluster-read, which names the one agent that gets it).
# Applied by layered-infra-ops with its role in the prod account, plan first,
# only on the owner's approval; never from CI and never from a branch. See
# README.md and ../../DESIGN.md.
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
#
# A second role, agent-broker-prod-edge-dns (bottom of this file), with the
# same trust: the agentrelay-edge-dns root's prod state, its load balancer
# lookups and its one certificate, and nothing else. Only ever issued with the
# owner's approval, for requests that name "profile": "edge-dns".

provider "aws" {
  region              = var.region
  profile             = var.profile
  allowed_account_ids = [var.prod_account_id]

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "infra-ops-cred-broker-prod-tf"
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
  cluster_arn = "arn:aws:eks:${var.region}:${var.prod_account_id}:cluster/${var.cluster_name}"
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
      Sid      = "DescribeTheProdCluster"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = [local.cluster_arn]
    }]
  }

  # The agentrelay-edge-dns root's prod state (enterprise-onboarding,
  # environments/agentrelay-edge-dns/prod.backend.hcl): bucket, key, S3 native
  # lockfile (use_lockfile = true: "<key>.tflock") and the state's KMS key.
  edge_dns_state_bucket     = "agentrelay-prod-tfstate-${var.prod_account_id}"
  edge_dns_state_bucket_arn = "arn:aws:s3:::${local.edge_dns_state_bucket}"
  edge_dns_state_key        = "${var.prod_account_id}/${var.region}/prod/edge-dns/terraform.tfstate"
  edge_dns_state_arn        = "${local.edge_dns_state_bucket_arn}/${local.edge_dns_state_key}"
  edge_dns_lock_arn         = "${local.edge_dns_state_arn}.tflock"
  edge_dns_state_kms_arn    = "arn:aws:kms:${var.region}:${var.prod_account_id}:key/${var.edge_dns_state_kms_key_id}"
  edge_dns_certificate_arn  = "arn:aws:acm:${var.region}:${var.prod_account_id}:certificate/${var.edge_dns_certificate_id}"

  # Exactly what `terraform plan` / `apply` of that root needs in AWS (the DNS
  # itself is Cloudflare): no EKS, IAM, Route 53 or other S3.
  edge_dns_permissions_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EdgeDnsStateReadWrite"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = [local.edge_dns_state_arn, local.edge_dns_lock_arn]
      },
      {
        # Terraform deletes the lockfile on unlock. Never the state object.
        Sid      = "EdgeDnsReleaseLock"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = [local.edge_dns_lock_arn]
      },
      {
        # The S3 backend's only list call is Workspaces(): ListObjectsV2 with
        # Prefix "<workspace_key_prefix>/" = "env:/" (the default; the root
        # sets none), made on every StateMgr (init, plan, apply). It never
        # lists with the state key (checked in hashicorp/terraform
        # internal/backend/remote-state/s3/backend_state.go, v1.7.0 to
        # v1.16.7). Terraform >= 1.8 tolerates AccessDenied here for the
        # default prefix, but the root allows >= 1.7, so allow exactly that
        # one prefix and nothing else in the bucket.
        Sid       = "EdgeDnsListWorkspaces"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.edge_dns_state_bucket_arn]
        Condition = { StringEquals = { "s3:prefix" = ["env:/"] } }
      },
      {
        Sid       = "EdgeDnsStateKeyViaS3"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = [local.edge_dns_state_kms_arn]
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } }
      },
      {
        # data.aws_lb (by tags): DescribeLoadBalancers, DescribeTags and, in
        # the provider's read, DescribeLoadBalancerAttributes. ELBv2 Describe
        # actions have no resource-level permissions in IAM: "*" only.
        Sid      = "EdgeDnsFindLoadBalancers"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeLoadBalancerAttributes"]
        Resource = ["*"]
      },
      {
        Sid      = "EdgeDnsReadCertificate"
        Effect   = "Allow"
        Action   = ["acm:DescribeCertificate", "acm:ListTagsForCertificate"]
        Resource = [local.edge_dns_certificate_arn]
      },
    ]
  }
}

resource "aws_iam_role" "read" {
  name                 = var.role_name
  description          = "Read-only prod EKS cluster sessions vended by the AWS credential broker (one named workspace agent, no approval)."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_iam_role_policy" "read" {
  name   = "describe-prod-cluster"
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

# The agentrelay-edge-dns root's prod plans and applies (enterprise-onboarding,
# environments/agentrelay-edge-dns): approval-tier only, vended by the broker
# for requests with "profile": "edge-dns" (broker/src/policy.ts), each one
# approved by the owner. Same trust as the read role; no EKS access entry.
resource "aws_iam_role" "edge_dns" {
  name                 = var.edge_dns_role_name
  description          = "agentrelay-edge-dns prod Terraform sessions vended by the AWS credential broker (owner-approved per request)."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}

resource "aws_iam_role_policy" "edge_dns" {
  name   = "agentrelay-edge-dns-prod"
  role   = aws_iam_role.edge_dns.id
  policy = jsonencode(local.edge_dns_permissions_policy)
}
