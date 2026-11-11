# Kubernetes access for the two CodeBuild roles.
#
# plan: the AmazonEKSViewPolicy in each namespace (no Secrets) plus the Kubernetes group "<name>-plan". Helm keeps
# release state in Secrets, so the plan job also needs get/list on Secrets in those namespaces: the Role and
# RoleBinding in output plan_rbac_manifest grant that to the group. Apply it once with cluster-admin rights
# (the apply job applies it again on every run, so it stays in code).
# apply: cluster admin. It is reachable only from the GitHub approval environment.

resource "aws_eks_access_entry" "build" {
  for_each          = local.modes
  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.build[each.key].arn
  type              = "STANDARD"
  kubernetes_groups = each.key == "plan" ? ["${var.name}-plan"] : []
  tags              = local.tags
}

resource "aws_eks_access_policy_association" "plan_view" {
  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.build["plan"].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  access_scope {
    type       = "namespace"
    namespaces = var.namespaces
  }
}

resource "aws_eks_access_policy_association" "apply_admin" {
  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.build["apply"].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

locals {
  plan_rbac_manifest = join("\n---\n", flatten([for ns in var.namespaces : [
    yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "Role"
      metadata   = { name = "${var.name}-plan-helm-state", namespace = ns }
      rules      = [{ apiGroups = [""], resources = ["secrets"], verbs = ["get", "list"] }]
    }),
    yamlencode({
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "RoleBinding"
      metadata   = { name = "${var.name}-plan-helm-state", namespace = ns }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "${var.name}-plan-helm-state" }
      subjects   = [{ apiGroup = "rbac.authorization.k8s.io", kind = "Group", name = "${var.name}-plan" }]
    }),
  ]]))
}
