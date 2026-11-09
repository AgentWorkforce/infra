resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
  depends_on        = [terraform_data.guard]
}
resource "aws_eks_cluster" "this" {
  name                      = local.name
  deletion_protection       = var.deletion_protection
  role_arn                  = aws_iam_role.this["cluster"].arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  vpc_config {
    subnet_ids              = [for az in local.azs : aws_subnet.private[az].id]
    endpoint_private_access = true
    endpoint_public_access  = var.public_api_enabled
    public_access_cidrs     = var.public_api_enabled ? var.operator_cidrs : null
    security_group_ids      = [aws_security_group.this["operator-api"].id]
  }
  encryption_config {
    resources = ["secrets"]
    provider { key_arn = var.kms_key_arn }
  }
  tags = local.tags
  # Routes do not attach their tables to subnets. Keep both associations ready
  # before the cluster/node/add-on chain and attached throughout its retirement.
  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.this,
    aws_route.nat,
    aws_route.internet,
    aws_route_table_association.public,
    aws_route_table_association.private,
  ]
}
resource "aws_eks_access_entry" "operator" {
  for_each      = var.operator_role_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  type          = "STANDARD"
  tags          = local.tags
}
resource "aws_eks_access_policy_association" "operator" {
  for_each      = var.operator_role_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.operator[each.key].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
resource "aws_eks_pod_identity_association" "cni" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-node"
  role_arn        = aws_iam_role.this["cni"].arn
  tags            = local.tags
}
resource "aws_eks_pod_identity_association" "ebs" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.this["ebs"].arn
  tags            = local.tags
}
resource "aws_eks_pod_identity_association" "lbc" {
  count           = var.enable_load_balancer_controller ? 1 : 0
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = local.pod_identity_service_accounts["lbc"]
  role_arn        = aws_iam_role.this["lbc"].arn
  tags            = local.tags
}
resource "aws_eks_addon" "bootstrap" {
  for_each                    = toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = var.addon_versions[each.key]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = local.tags
  depends_on                  = [aws_eks_pod_identity_association.cni, aws_vpc_endpoint.eks_auth]
}
locals {
  node_groups = {
    general = { capacity = var.capacity, instance = var.instance_type, azs = local.azs }
    actors  = { capacity = var.actor_capacity, instance = var.actor_instance_type, azs = [contains(local.azs, var.actor_availability_zone) ? var.actor_availability_zone : local.azs[0]] }
  }
}
resource "aws_launch_template" "node" {
  for_each               = local.node_groups
  name_prefix            = "${local.name}-${each.key}-"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.this["workload"].id, aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-${each.key}" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }
  tag_specifications {
    resource_type = "network-interface"
    tags          = local.tags
  }
  tags = local.tags
}
resource "aws_eks_node_group" "this" {
  for_each        = local.node_groups
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-${each.key}"
  node_role_arn   = aws_iam_role.this["node"].arn
  subnet_ids      = [for az in each.value.azs : aws_subnet.private[az].id]
  instance_types  = [each.value.instance]
  ami_type        = "AL2023_x86_64_STANDARD"
  release_version = var.node_ami_release_version
  version         = var.kubernetes_version
  capacity_type   = "ON_DEMAND"
  scaling_config {
    min_size     = each.value.capacity.min
    desired_size = each.value.capacity.desired
    max_size     = each.value.capacity.max
  }
  update_config { max_unavailable = 1 }
  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }
  labels = each.key == "actors" ? { "durable-actors/role" = "actor-host" } : { "agent-relay/role" = "general" }
  dynamic "taint" {
    for_each = each.key == "actors" ? [1] : []
    content {
      key    = "durable-actors/actor-host"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
  tags       = local.tags
  depends_on = [aws_eks_addon.bootstrap, aws_iam_role_policy_attachment.this, aws_route.nat, aws_route.internet]
}
resource "aws_eks_addon" "storage_dns" {
  for_each                    = toset(["coredns", "aws-ebs-csi-driver"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = var.addon_versions[each.key]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = local.tags
  depends_on                  = [aws_eks_node_group.this, aws_eks_pod_identity_association.ebs, aws_iam_role_policy.ebs_kms]
}
