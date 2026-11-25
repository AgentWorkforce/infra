# Plan-only, mocked provider: no AWS credentials, no state, no apply.
mock_provider "aws" {
  override_data {
    target = data.aws_eks_cluster.this
    values = {
      name = "agent-relay-prod"
      access_config = [{
        authentication_mode                         = "API_AND_CONFIG_MAP"
        bootstrap_cluster_creator_admin_permissions = false
      }]
    }
  }
}

# Placeholder ids: the real account id lives only in allowlist.json, and the run
# that pairs this root with the allowlist reads it from there.
variables {
  prod_account_id = "111111111111"
  broker_role_arn = "arn:aws:iam::222222222222:role/agent-cred-broker"
}

run "trusts_only_the_broker_with_its_tags_and_source_identity" {
  command = plan
  assert {
    condition     = length(output.trust_policy.Statement) == 3 && alltrue([for s in output.trust_policy.Statement : s.Principal.AWS == var.broker_role_arn && s.Effect == "Allow"])
    error_message = "every trust statement names only the broker role"
  }
  assert {
    condition     = output.trust_policy.Statement[0].Condition.Null == { "aws:RequestTag/agent-run" = "false", "aws:RequestTag/agent-ns" = "false", "aws:RequestTag/agent" = "false", "sts:SourceIdentity" = "false" }
    error_message = "AssumeRole requires the broker's tags and a source identity"
  }
  assert {
    condition     = output.trust_policy.Statement[1].Condition["ForAllValues:StringEquals"]["aws:TagKeys"] == ["broker-request-id", "agent-run", "agent-ns", "agent"]
    error_message = "only the broker's session tag keys"
  }
  assert {
    condition     = aws_iam_role.read.max_session_duration == 3600
    error_message = "1 h cap"
  }
}

run "trust_matches_the_other_broker_target_roles" {
  command = plan
  # The same three statements as the elevated role's trust: a reviewer can diff them.
  assert {
    condition     = [for s in output.trust_policy.Statement : s.Sid] == ["BrokerAssumesWithRequestTags", "BrokerTagsSessions", "BrokerSetsSourceIdentity"]
    error_message = "same trust statements as modules/elevated-role"
  }
  assert {
    condition     = strcontains(file("${path.module}/../modules/elevated-role/main.tf"), "Sid       = \"BrokerAssumesWithRequestTags\"") && strcontains(file("${path.module}/../modules/elevated-role/main.tf"), "\"aws:RequestTag/broker-request-id\" = \"cb-*\"")
    error_message = "the elevated role still has the trust this mirrors"
  }
}

run "the_roles_only_aws_permission_is_describe_on_the_one_cluster" {
  command = plan
  assert {
    condition     = length(output.permissions_policy.Statement) == 1 && output.permissions_policy.Statement[0].Effect == "Allow"
    error_message = "one allow, nothing else"
  }
  assert {
    condition     = output.permissions_policy.Statement[0].Action == ["eks:DescribeCluster"]
    error_message = "eks:DescribeCluster only"
  }
  assert {
    condition     = output.permissions_policy.Statement[0].Resource == ["arn:aws:eks:us-west-2:${var.prod_account_id}:cluster/agent-relay-prod"] && output.cluster_arn == "arn:aws:eks:us-west-2:${var.prod_account_id}:cluster/agent-relay-prod"
    error_message = "that cluster, in this account and region, no wildcard"
  }
  assert {
    condition     = !strcontains(jsonencode(output.permissions_policy), "*") && !strcontains(aws_iam_role_policy.read.policy, "*")
    error_message = "no wildcard anywhere in the permissions"
  }
}

run "kubernetes_side_is_the_aws_view_policy_at_cluster_scope_and_nothing_else" {
  command = plan
  assert {
    condition     = aws_eks_access_entry.read.cluster_name == "agent-relay-prod" && aws_eks_access_entry.read.type == "STANDARD"
    error_message = "a standard access entry on the prod cluster"
  }
  assert {
    condition     = !strcontains(file("${path.module}/main.tf"), "kubernetes_groups")
    error_message = "no Kubernetes groups (a group could bind to more than view)"
  }
  assert {
    condition     = aws_eks_access_policy_association.view.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "AmazonEKSViewPolicy: Kubernetes view, no Secrets, no writes"
  }
  assert {
    condition     = aws_eks_access_policy_association.view.access_scope[0].type == "cluster" && aws_eks_access_policy_association.view.access_scope[0].namespaces == null
    error_message = "cluster scope"
  }
  assert {
    condition     = aws_eks_access_policy_association.view.cluster_name == "agent-relay-prod"
    error_message = "on the prod cluster"
  }
}

run "matches_the_broker_allowlist" {
  command = plan
  variables {
    prod_account_id = one([for k, a in jsondecode(file("../../allowlist.json")).accounts : k if a.label == "agentrelay-prod"])
  }
  assert {
    condition     = "arn:aws:iam::${var.prod_account_id}:role/${output.role_name}" == jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.prod_account_id].roles.elevated
    error_message = "the allowlist's role for the prod account is the one this creates"
  }
  assert {
    condition     = "arn:aws:iam::${var.prod_account_id}:role/${output.edge_dns_role_name}" == jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.prod_account_id].roles.edgeDns
    error_message = "the allowlist's edge-dns role for the prod account is the one this creates"
  }
  assert {
    condition     = strcontains(file("${path.module}/../../src/policy.ts"), "key/${var.edge_dns_state_kms_key_id}") && strcontains(file("${path.module}/../../src/policy.ts"), "certificate/${var.edge_dns_certificate_id}")
    error_message = "the broker's edge-dns profile names the same state key and certificate as this role"
  }
  assert {
    condition     = jsondecode(file("${path.module}/../../allowlist.json")).accounts[var.prod_account_id].regions == [var.region]
    error_message = "the allowlist's one region is the cluster's"
  }
  assert {
    condition = anytrue([
      for c in jsondecode(file("${path.module}/../../allowlist.json")).workspaceAuto.capabilities :
      # try(): Terraform 1.11 evaluates both sides of &&, and other capabilities' grants have no eksClusters.
      try(c.accounts == [var.prod_account_id] && c.regions == [var.region] && length(c.grants) == 1 && c.grants[0].actions == ["eks:DescribeCluster"] && c.grants[0].eksClusters == [var.cluster_name] && !contains(keys(c), "readOnlyRules"), false)
    ])
    error_message = "the workspaceAuto capability names this account, region, cluster and the one action"
  }
  assert {
    condition = alltrue([
      for c in jsondecode(file("${path.module}/../../allowlist.json")).workspaceAuto.capabilities :
      try(length(c.requesters) > 0, false) if contains(c.accounts, var.prod_account_id)
    ])
    error_message = "every workspaceAuto capability in the prod account is limited to named requesters"
  }
  assert {
    condition = alltrue([
      for d in try(jsondecode(file("${path.module}/../../allowlist.json")).delegatedApprovers, []) :
      alltrue([for c in d.capabilities : !contains(c.accounts, var.prod_account_id)])
    ])
    error_message = "no delegated approver has a capability in the prod account"
  }
}

run "edge_dns_role_has_the_same_trust_and_a_1h_cap" {
  command = plan
  assert {
    condition     = aws_iam_role.edge_dns.assume_role_policy == aws_iam_role.read.assume_role_policy && aws_iam_role.edge_dns.assume_role_policy == jsonencode(output.trust_policy)
    error_message = "the edge-dns role trusts exactly what the read role trusts: the broker, with its tags and a source identity"
  }
  assert {
    condition     = aws_iam_role.edge_dns.name == "agent-broker-prod-edge-dns" && aws_iam_role.edge_dns.max_session_duration == 3600
    error_message = "agent-broker-prod-edge-dns, 1 h cap"
  }
  assert {
    condition     = !strcontains(file("${path.module}/main.tf"), "aws_eks_access_entry\" \"edge_dns")
    error_message = "the edge-dns role is no Kubernetes principal"
  }
}

run "edge_dns_policy_is_exactly_the_state_the_load_balancer_lookups_and_one_certificate" {
  command = plan
  variables {
    prod_account_id = "786098391924"
  }
  assert {
    condition = output.edge_dns_permissions_policy == {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "EdgeDnsStateReadWrite"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = ["arn:aws:s3:::agentrelay-prod-tfstate-786098391924/786098391924/us-west-2/prod/edge-dns/terraform.tfstate", "arn:aws:s3:::agentrelay-prod-tfstate-786098391924/786098391924/us-west-2/prod/edge-dns/terraform.tfstate.tflock"]
        },
        {
          Sid      = "EdgeDnsReleaseLock"
          Effect   = "Allow"
          Action   = ["s3:DeleteObject"]
          Resource = ["arn:aws:s3:::agentrelay-prod-tfstate-786098391924/786098391924/us-west-2/prod/edge-dns/terraform.tfstate.tflock"]
        },
        {
          Sid       = "EdgeDnsListWorkspaces"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = ["arn:aws:s3:::agentrelay-prod-tfstate-786098391924"]
          Condition = { StringEquals = { "s3:prefix" = ["env:/"] } }
        },
        {
          Sid       = "EdgeDnsStateKeyViaS3"
          Effect    = "Allow"
          Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource  = ["arn:aws:kms:us-west-2:786098391924:key/717fa644-8436-4042-abfa-0ddaa9b696c9"]
          Condition = { StringEquals = { "kms:ViaService" = "s3.us-west-2.amazonaws.com" } }
        },
        {
          Sid      = "EdgeDnsFindLoadBalancers"
          Effect   = "Allow"
          Action   = ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeLoadBalancerAttributes"]
          Resource = ["*"]
        },
        {
          Sid      = "EdgeDnsReadCertificate"
          Effect   = "Allow"
          Action   = ["acm:DescribeCertificate", "acm:ListTagsForCertificate"]
          Resource = ["arn:aws:acm:us-west-2:786098391924:certificate/4a0284eb-d27f-4aaa-8185-0cc2dd87cac0"]
        },
      ]
    }
    error_message = "the edge-dns role's policy is pinned: exactly these actions on exactly these resources"
  }
  assert {
    condition     = aws_iam_role_policy.edge_dns.policy == jsonencode(output.edge_dns_permissions_policy)
    error_message = "the inline policy is the pinned one"
  }
}

run "edge_dns_policy_never_widens" {
  command = plan
  assert {
    condition     = alltrue([for s in output.edge_dns_permissions_policy.Statement : s.Effect == "Allow" && !contains(keys(s), "NotAction") && !contains(keys(s), "NotResource")])
    error_message = "plain allows only"
  }
  assert {
    condition     = alltrue([for s in output.edge_dns_permissions_policy.Statement : alltrue([for a in s.Action : !strcontains(a, "*") && contains(["s3", "kms", "elasticloadbalancing", "acm"], split(":", a)[0])])])
    error_message = "no wildcard action, and no service but S3, KMS, ELB and ACM (no EKS, IAM, Route 53)"
  }
  assert {
    condition     = alltrue([for s in output.edge_dns_permissions_policy.Statement : s.Resource == ["*"] if anytrue([for r in s.Resource : strcontains(r, "*")])]) && one([for s in output.edge_dns_permissions_policy.Statement : s.Action if s.Resource == ["*"]]) == ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeLoadBalancerAttributes"]
    error_message = "the only wildcard resource is \"*\", for the ELB Describe actions alone (no resource-level permissions)"
  }
  assert {
    condition     = one([for s in output.edge_dns_permissions_policy.Statement : s.Resource if contains(s.Action, "s3:DeleteObject")]) == ["arn:aws:s3:::agentrelay-prod-tfstate-${var.prod_account_id}/${var.prod_account_id}/us-west-2/prod/edge-dns/terraform.tfstate.tflock"]
    error_message = "s3:DeleteObject only on the lockfile, never the state"
  }
  assert {
    condition     = length([for s in output.edge_dns_permissions_policy.Statement : s if contains(s.Action, "s3:ListBucket")]) == 1 && one([for s in output.edge_dns_permissions_policy.Statement : s.Condition if contains(s.Action, "s3:ListBucket")]) == { StringEquals = { "s3:prefix" = ["env:/"] } }
    error_message = "s3:ListBucket only for the S3 backend's one listing: prefix env:/ (Workspaces), exact match"
  }
  assert {
    condition     = one([for s in output.edge_dns_permissions_policy.Statement : s.Condition if contains(s.Action, "kms:Decrypt")]) == { StringEquals = { "kms:ViaService" = "s3.us-west-2.amazonaws.com" } }
    error_message = "the state key only through S3 in the region"
  }
}

run "refuses_a_cluster_that_cannot_take_access_entries" {
  command = plan
  override_data {
    target = data.aws_eks_cluster.this
    values = {
      name = "agent-relay-prod"
      access_config = [{
        authentication_mode                         = "CONFIG_MAP"
        bootstrap_cluster_creator_admin_permissions = false
      }]
    }
  }
  expect_failures = [data.aws_eks_cluster.this]
}

run "rejects_wildcards_and_a_malformed_broker_role" {
  command = plan
  variables {
    cluster_name    = "agent-relay-*"
    broker_role_arn = "arn:aws:iam::222222222222:role/*"
  }
  expect_failures = [var.cluster_name, var.broker_role_arn]
}

run "rejects_a_wildcard_state_key_or_certificate" {
  command = plan
  variables {
    edge_dns_state_kms_key_id = "*"
    edge_dns_certificate_id   = "4a0284eb-*"
  }
  expect_failures = [var.edge_dns_state_kms_key_id, var.edge_dns_certificate_id]
}
