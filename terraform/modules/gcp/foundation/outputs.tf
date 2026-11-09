output "identity" {
  description = "Verified project/environment contract; existing org, billing and parent DNS remain external."
  value = {
    project_id     = var.project_id
    project_number = var.expected_project_number
    environment    = var.environment
    region         = var.region
  }
  depends_on = [terraform_data.fence]
}
output "network" {
  description = "Data-state inputs: postgres network_self_link/allocated_ip_range, and functions vpc_connector. PSA completion is an explicit dependency."
  value = {
    self_link                    = google_compute_network.this.self_link
    id                           = google_compute_network.this.id
    subnet_self_link             = google_compute_subnetwork.nodes.self_link
    pod_range_name               = "pods"
    service_range_name           = "services"
    ranges                       = var.network_ranges
    allocated_ip_range           = google_compute_global_address.private_services.name
    private_services_connection  = google_service_networking_connection.private_services.id
    functions_vpc_connector      = try(google_vpc_access_connector.this[0].id, null)
    functions_vpc_connector_name = try(google_vpc_access_connector.this[0].name, null)
    nat_enabled                  = var.enable_nat
  }
  depends_on = [google_service_networking_connection.private_services]
}
output "gke" {
  description = "Non-secret application/search state inputs. Use gke-gcloud-auth-plugin exec later; never store google_client_config access_token in any state. Private endpoint requires approved routed operator access and IAM/RBAC."
  value = {
    name                        = google_container_cluster.this.name
    location                    = google_container_cluster.this.location
    id                          = google_container_cluster.this.id
    private_endpoint            = google_container_cluster.this.private_cluster_config[0].private_endpoint
    public_api_enabled          = var.public_api_enabled
    workload_pool               = local.wi_pool
    node_service_account        = google_service_account.nodes.email
    persistent_disk_csi_enabled = true
  }
}
output "workload_identity" {
  description = "Namespace/KSA direct-principal contract for data IAM, without keys or workload-wide IAM grants. Use one subject per exact namespace/service account."
  value = {
    workload_pool               = local.wi_pool
    principal_template          = "${local.wi_prefix}/ns/<namespace>/sa/<service-account>"
    gsa_binding_member_template = "serviceAccount:${local.wi_pool}[<namespace>/<service-account>]"
    pipeline_publishers         = { for k in var.pipeline.publishers : k => "${local.wi_prefix}/ns/${split("/", k)[0]}/sa/${split("/", k)[1]}" if var.pipeline.enabled }
    pipeline_subscribers        = { for k in var.pipeline.subscribers : k => "${local.wi_prefix}/ns/${split("/", k)[0]}/sa/${split("/", k)[1]}" if var.pipeline.enabled }
  }
}
output "actor_host_profile" {
  description = "Opt-in GCP chart placement contract. GKE installs native sandbox.gke.io/runtime=gvisor node label/taint and RuntimeClass toleration; no EKS actor-host taint is added. This is not untrusted multi-tenant isolation or an application HA claim."
  value = var.actor_hosts.enabled ? {
    node_pool          = google_container_node_pool.this["actors"].name
    placement_zone     = var.actor_hosts.zone
    runtime_class_name = "gvisor"
    node_selector      = { "sandbox.gke.io/runtime" = "gvisor" }
    taint              = { key = "sandbox.gke.io/runtime", value = "gvisor", effect = "NoSchedule" }
    toleration_source  = "GKE gvisor RuntimeClass admission"
  } : null
}
output "pipeline" {
  description = "Native pipeline non-secret Pub/Sub and optional Redis references. Redis password is intentionally never output; provider state still contains generated AUTH when managed Redis is enabled."
  value = {
    topic_id                    = try(google_pubsub_topic.pipeline[0].id, null)
    subscription_id             = try(google_pubsub_subscription.pipeline[0].id, null)
    dead_letter_topic_id        = try(google_pubsub_topic.dead_letter[0].id, null)
    dead_letter_subscription_id = try(google_pubsub_subscription.dead_letter[0].id, null)
    redis = var.redis.enabled ? {
      id            = google_redis_instance.pipeline[0].id
      host          = google_redis_instance.pipeline[0].host
      port          = google_redis_instance.pipeline[0].port
      tls_required  = true
      auth_required = true
      # Public server CA data; marked sensitive by some provider versions.
      ca_certs = nonsensitive(google_redis_instance.pipeline[0].server_ca_certs)
    } : null
  }
}
