output "account_id" {
  description = "Existing fenced AWS account."
  value       = var.account_id
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "environment" {
  description = "Environment identity."
  value       = var.environment
}

output "vpc_id" {
  description = "Environment VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnets in two or three sorted AZs."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "database_security_group_ids" {
  description = "Postgres destination groups, TCP 5432 from environment nodes/functions only."
  value       = [aws_security_group.this["database"].id]
}

output "search_subnet_ids" {
  description = "One, two or three private AZ subnets selected for OpenSearch."
  value       = [for az in slice(local.azs, 0, min(var.search_az_count, length(local.azs))) : aws_subnet.private[az].id]
}

output "search_security_group_ids" {
  description = "OpenSearch destination groups, TCP 443 from environment nodes/functions only."
  value       = [aws_security_group.this["search"].id]
}

output "function_security_group_ids" {
  description = "Lambda source group with private PostgreSQL/DNS and HTTPS NAT egress."
  value       = [aws_security_group.this["function"].id]
}

output "workload_security_group_ids" {
  description = "Node-scoped workload groups; does not isolate individual Pods."
  value       = [aws_security_group.this["workload"].id]
}

output "eks_cluster_name" {
  description = "EKS cluster for later Pod Identity association."
  value       = aws_eks_cluster.this.name
}

output "cluster_security_group_id" {
  description = "AWS service-created group; inventory and retirement require explicit verification."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "namespace" {
  description = "Application namespace reference; not created here."
  value       = local.namespace
}

output "identity_references" {
  description = "References for data/application-owned workload roles; no tokens or credentials."
  value = {
    role_path                = local.role_path
    permissions_boundary_arn = local.boundary
    cluster_name             = aws_eks_cluster.this.name
    namespace                = local.namespace
    service_accounts = {
      durable_actors = "${var.release_name}-durable-actors"
      worker         = "${var.release_name}-worker"
      alleyoop       = "${var.release_name}-session-ingest-api"
    }
  }
}

output "actor_profile" {
  description = "Values under durable-actors matching values-eks-actors.yaml; first-party only."
  value = {
    placement = { zone = var.actor_availability_zone }
    sandbox = {
      runtimeClassName = ""
      nodeSelector     = { "durable-actors/role" = "actor-host" }
      tolerations      = [{ key = "durable-actors/actor-host", operator = "Exists", effect = "NoSchedule" }]
    }
  }
}

output "storage_class_manifest" {
  description = "Application applies this manifest via exec-auth; retained PVs require separate recovery/retirement approval."
  value = {
    apiVersion           = "storage.k8s.io/v1"
    kind                 = "StorageClass"
    metadata             = { name = "${local.name}-gp3" }
    provisioner          = "ebs.csi.aws.com"
    reclaimPolicy        = "Retain"
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
    parameters           = { type = "gp3", encrypted = "true", kmsKeyId = var.kms_key_arn }
  }
}
