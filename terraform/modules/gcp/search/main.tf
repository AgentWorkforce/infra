locals {
  service_account = "${var.name}-opensearch"

  cluster_values = {
    serviceAccount = {
      create      = true
      name        = local.service_account
      annotations = var.service_account_annotations
    }
    cluster = {
      name = var.name
      general = {
        version          = var.opensearch_version
        image            = var.image
        httpPort         = 9200
        serviceName      = var.name
        serviceAccount   = local.service_account
        setVMMaxMapCount = var.set_vm_max_map_count
        drainDataNodes   = true
        pluginsList      = var.plugins
        # runAsNonRoot would block the operator's privileged sysctl init
        # container, so it is set only when that container is off.
        podSecurityContext = {
          fsGroup        = 1000
          runAsNonRoot   = var.set_vm_max_map_count ? null : true
          runAsUser      = var.set_vm_max_map_count ? null : 1000
          seccompProfile = { type = "RuntimeDefault" }
        }
      }
      dashboards = {
        enable  = var.dashboards_enabled
        version = var.opensearch_version
      }
      nodePools = [{
        component    = "nodes"
        replicas     = var.replicas
        diskSize     = var.disk_size
        roles        = ["cluster_manager", "data", "ingest"]
        resources    = var.resources
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
        persistence = {
          pvc = merge(
            { accessModes = ["ReadWriteOnce"] },
            var.storage_class == null ? {} : { storageClass = var.storage_class },
          )
        }
      }]
      security = {
        config = {
          adminCredentialsSecret = { name = var.admin_credentials_secret_name }
          securityConfigSecret   = { name = var.security_config_secret_name }
        }
        tls = {
          # Operator-generated CA and certificates: TLS on transport and HTTP.
          transport = { generate = true, perNode = true }
          http      = { generate = true }
        }
      }
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = var.labels
  }
}

resource "helm_release" "operator" {
  count = var.install_operator ? 1 : 0

  name             = "opensearch-operator"
  namespace        = var.operator_namespace
  create_namespace = true
  repository       = var.chart_repository
  chart            = "opensearch-operator"
  version          = var.operator_chart_version
  atomic           = true
  wait             = true
}

resource "helm_release" "cluster" {
  name       = var.name
  namespace  = kubernetes_namespace_v1.this.metadata[0].name
  repository = var.chart_repository
  chart      = "opensearch-cluster"
  version    = var.cluster_chart_version
  # The operator brings the cluster up after the CR is accepted; Helm only
  # waits for the CR and service account.
  wait   = false
  values = concat([yamlencode(local.cluster_values)], var.additional_values)

  depends_on = [helm_release.operator]
}

resource "kubernetes_network_policy_v1" "this" {
  count = var.network_policy.enabled ? 1 : 0

  metadata {
    name      = "${var.name}-ingress"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    # The cluster's own pods: HTTP and node-to-node transport.
    ingress {
      from {
        pod_selector {}
      }
    }

    # The operator and the allowed namespaces: the HTTP API (9200) and, with
    # Dashboards on, the Dashboards port (5601) only.
    ingress {
      ports {
        port     = "9200"
        protocol = "TCP"
      }
      dynamic "ports" {
        for_each = var.dashboards_enabled ? [1] : []
        content {
          port     = "5601"
          protocol = "TCP"
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.operator_namespace }
        }
      }
      dynamic "from" {
        for_each = var.network_policy.allowed_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
    }
  }
}
