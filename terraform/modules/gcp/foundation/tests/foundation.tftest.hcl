mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
  mock_resource "google_compute_network" {
    defaults = { id = "projects/example-project/global/networks/example-development", self_link = "https://www.googleapis.com/compute/v1/projects/example-project/global/networks/example-development" }
  }
}
# OpenTofu may synthesize identical IDs for resources of the same mocked type.
# Give the two NAT subnets distinct stable IDs so set comparison tests topology.
override_resource {
  target = google_compute_subnetwork.nodes
  values = { id = "projects/example-project/regions/us-central1/subnetworks/example-development-nodes" }
}
override_resource {
  target = google_compute_subnetwork.connector
  values = { id = "projects/example-project/regions/us-central1/subnetworks/example-development-connector" }
}
variables {
  project_id              = "example-project"
  expected_project_number = "123456789012"
  name                    = "example"
  environment             = "development"
  expected_environment    = "development"
  region                  = "us-central1"
  node_locations          = ["us-central1-a", "us-central1-b", "us-central1-c"]
  gke_version             = "1.34.1-gke.1000000"
  release_channel         = "STABLE"
  operator_cidrs          = { approved-vpn = "10.100.0.0/24" }
  maintenance_window      = { start_time = "2030-01-05T00:00:00Z", end_time = "2030-01-06T00:00:00Z", recurrence = "FREQ=WEEKLY;BYDAY=SA,SU" }
  network_ranges = {
    nodes            = "10.10.0.0/20"
    pods             = "10.20.0.0/16"
    services         = "10.30.0.0/20"
    control_plane    = "10.40.0.0/28"
    private_services = "10.50.0.0/16"
    connector        = "10.60.0.0/28"
  }
}
run "private_foundation_and_data_handoff" {
  command = apply
  assert {
    condition     = google_compute_firewall.deny_ingress.network == google_compute_network.this.id && google_compute_firewall.deny_ingress.direction == "INGRESS" && google_compute_firewall.deny_ingress.priority == 65534 && google_compute_firewall.deny_ingress.source_ranges == toset(["0.0.0.0/0"]) && length(google_compute_firewall.deny_ingress.allow) == 0 && one(google_compute_firewall.deny_ingress.deny).protocol == "all" && google_compute_firewall.deny_ingress.log_config[0].metadata == "EXCLUDE_ALL_METADATA"
    error_message = "The owned VPC needs an explicit logged deny-all ingress baseline with no new allows, below the priority of platform GKE/connector allow rules."
  }
  assert {
    condition     = !google_compute_network.this.auto_create_subnetworks && google_compute_subnetwork.nodes.private_ip_google_access && length(google_compute_subnetwork.nodes.secondary_ip_range) == 2
    error_message = "Dedicated VPC, private Google API connectivity and pod/service ranges are required."
  }
  assert {
    condition     = google_container_cluster.this.location == var.region && google_container_cluster.this.private_cluster_config[0].enable_private_nodes && google_container_cluster.this.private_cluster_config[0].enable_private_endpoint && google_container_cluster.this.master_authorized_networks_config[0].private_endpoint_enforcement_enabled && !google_container_cluster.this.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled
    error_message = "Regional cluster must have private nodes and enforced operator allowlist on private API."
  }
  assert {
    condition     = google_container_cluster.this.resource_labels["environment"] == var.environment && google_container_cluster.this.resource_labels["managed-by"] == "terraform" && google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH" && google_container_cluster.this.workload_identity_config[0].workload_pool == "example-project.svc.id.goog" && google_container_cluster.this.addons_config[0].gce_persistent_disk_csi_driver_config[0].enabled
    error_message = "Dataplane V2, Workload Identity and PD CSI must compose with application/search state."
  }
  assert {
    condition     = google_container_cluster.this.deletion_protection && google_service_networking_connection.private_services.deletion_policy == "ABANDON" && length(google_compute_router_nat.this) == 0 && length(google_redis_instance.pipeline) == 0
    error_message = "Protect cluster and PSA by default; egress and managed credentials require opt-in."
  }
  assert {
    condition     = output.network.self_link == google_compute_network.this.self_link && output.network.allocated_ip_range == google_compute_global_address.private_services.name && output.network.functions_vpc_connector == google_vpc_access_connector.this[0].id && output.gke.name == google_container_cluster.this.name && output.gke.location == var.region
    error_message = "Foundation outputs must directly feed existing postgres/functions/search inputs."
  }
  assert {
    condition     = google_container_node_pool.this["system"].node_config[0].service_account == google_service_account.nodes.email && google_container_node_pool.this["system"].node_config[0].workload_metadata_config[0].mode == "GKE_METADATA" && google_project_iam_member.nodes.role == "roles/container.defaultNodeServiceAccount"
    error_message = "Custom node identity has node-only role and metadata isolation, with workload access through WI."
  }
}
run "explicit_optional_native_services" {
  command = apply
  variables {
    enable_nat         = true
    public_api_enabled = true
    actor_hosts        = { enabled = true, zone = "us-central1-a" }
    pipeline           = { enabled = true, publishers = ["example/worker"], subscribers = ["example/alleyoop"] }
    redis              = { enabled = true, acknowledge_auth_in_state = true, version = "REDIS_7_2" }
  }
  assert {
    condition     = !google_container_cluster.this.private_cluster_config[0].enable_private_endpoint && length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 1 && length(google_compute_router_nat.this[0].subnetwork) == 2
    error_message = "Public API remains scoped and NAT covers only explicit nodes and connector subnets."
  }
  assert {
    condition     = google_container_node_pool.this["actors"].node_config[0].sandbox_config[0].type == "GVISOR" && output.actor_host_profile.node_selector["sandbox.gke.io/runtime"] == "gvisor" && output.actor_host_profile.placement_zone == "us-central1-a"
    error_message = "GCP actors require actual chart GKE Sandbox placement, not an EKS taint."
  }
  assert {
    condition     = google_redis_instance.pipeline[0].auth_enabled && google_redis_instance.pipeline[0].transit_encryption_mode == "SERVER_AUTHENTICATION" && google_redis_instance.pipeline[0].connect_mode == "PRIVATE_SERVICE_ACCESS" && google_redis_instance.pipeline[0].deletion_protection
    error_message = "Managed Redis requires TLS, AUTH, PSA and deletion protection."
  }
  assert {
    condition     = google_pubsub_topic_iam_member.publisher["example/worker"].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-project.svc.id.goog/subject/ns/example/sa/worker" && google_pubsub_subscription_iam_member.subscriber["example/alleyoop"].role == "roles/pubsub.subscriber" && google_pubsub_subscription.pipeline[0].dead_letter_policy[0].dead_letter_topic == output.pipeline.dead_letter_topic_id && google_pubsub_subscription.pipeline[0].deletion_policy == "PREVENT" && google_pubsub_topic.pipeline[0].deletion_policy == "PREVENT"
    error_message = "Native queue IAM must bind exact workload principals with a held dead-letter path."
  }
  assert {
    condition     = output.pipeline.redis.auth_required && output.pipeline.redis.tls_required && !contains(keys(output.pipeline.redis), "auth_string")
    error_message = "Only non-secret Redis references are exported (provider state is still sensitive)."
  }
}
run "project_number_mismatch_refused" {
  command = plan
  variables { expected_project_number = "999999999999" }
  expect_failures = [terraform_data.fence]
}
run "environment_mismatch_refused" {
  command = plan
  variables { expected_environment = "production" }
  expect_failures = [terraform_data.fence]
}
run "unknown_environment_refused" {
  command = plan
  variables { environment = "typo" }
  expect_failures = [var.environment]
}
run "public_wide_api_refused" {
  command = plan
  variables { operator_cidrs = { world = "0.0.0.0/0" } }
  expect_failures = [var.operator_cidrs]
}
run "empty_operator_access_refused" {
  command = plan
  variables { operator_cidrs = {} }
  expect_failures = [var.operator_cidrs]
}
run "overlapping_networks_refused" {
  command = plan
  variables {
    network_ranges = { nodes = "10.10.0.0/20", pods = "10.10.0.0/16", services = "10.30.0.0/20", control_plane = "10.40.0.0/28", private_services = "10.50.0.0/16", connector = "10.60.0.0/28" }
  }
  expect_failures = [terraform_data.fence]
}
run "public_nodes_range_refused" {
  command = plan
  variables {
    network_ranges = { nodes = "8.8.0.0/20", pods = "10.20.0.0/16", services = "10.30.0.0/20", control_plane = "10.40.0.0/28", private_services = "10.50.0.0/16", connector = "10.60.0.0/28" }
  }
  expect_failures = [terraform_data.fence]
}
run "actor_zone_mismatch_refused" {
  command = plan
  variables { actor_hosts = { enabled = true, zone = "europe-west1-b" } }
  expect_failures = [var.actor_hosts]
}
run "redis_state_risk_requires_acknowledgment" {
  command = plan
  variables { redis = { enabled = true, version = "REDIS_7_2" } }
  expect_failures = [var.redis]
}
run "guessed_gke_latest_refused" {
  command = plan
  variables { gke_version = "latest" }
  expect_failures = [var.gke_version]
}

run "malformed_project_refused" {
  command = plan
  variables { project_id = "not/a/project" }
  expect_failures = [var.project_id]
}
run "non_ipv4_operator_refused" {
  command = plan
  variables { operator_cidrs = { world = "::/0" } }
  expect_failures = [var.operator_cidrs]
}
run "retirement_requires_explicit_protection_change" {
  command = plan
  variables {
    deletion_protection = false
    pipeline            = { enabled = true }
  }
  assert {
    condition     = !google_container_cluster.this.deletion_protection && google_pubsub_topic.pipeline[0].deletion_policy == "DELETE" && google_pubsub_subscription.pipeline[0].deletion_policy == "DELETE" && google_service_networking_connection.private_services.deletion_policy == "ABANDON"
    error_message = "Reviewed protection release affects owned compute/queues but must never disconnect retained managed data automatically."
  }
}

run "connector_max_prefix" {
  command = plan
  variables { name = "abcdefghijkl" }
  assert {
    condition     = length(replace(google_vpc_access_connector.this[0].name, "-", "--")) == 20 && can(regex("^ar-[0-9a-f]{16}$", google_vpc_access_connector.this[0].name)) && google_vpc_access_connector.this[0].name == "ar-633791c1058fb35d" && output.network.functions_vpc_connector_name == google_vpc_access_connector.this[0].name
    error_message = "A maximum-length accepted prefix must produce a valid connector name below Google's 21 effective-character limit, with hyphens counted twice."
  }
}
# Frozen baseline from connector_max_prefix keeps comparisons portable across
# Terraform/OpenTofu test engines that differ in cross-run reference support.
run "connector_hyphen_heavy_prefix" {
  command = plan
  variables { name = "a-----------" }
  assert {
    condition     = length(replace(google_vpc_access_connector.this[0].name, "-", "--")) < 21 && google_vpc_access_connector.this[0].name != "ar-633791c1058fb35d"
    error_message = "The most hyphen-heavy accepted prefix must remain bounded and distinct from another accepted name."
  }
}
run "connector_environment_disambiguation" {
  command = plan
  variables {
    name                 = "abcdefghijkl"
    environment          = "staging"
    expected_environment = "staging"
  }
  assert {
    condition     = length(replace(google_vpc_access_connector.this[0].name, "-", "--")) < 21 && google_vpc_access_connector.this[0].name != "ar-633791c1058fb35d"
    error_message = "The same installation prefix in different environments must create different valid connector names."
  }
}
run "connector_full_prefix_disambiguation" {
  command = plan
  variables { name = "abcdefghijkm" }
  assert {
    condition     = google_vpc_access_connector.this[0].name != "ar-633791c1058fb35d" && length(replace(google_vpc_access_connector.this[0].name, "-", "--")) < 21
    error_message = "Distinct accepted prefixes sharing their first eleven characters must not collapse after truncation."
  }
}
run "connector_agent_relay_regression" {
  command = plan
  variables { name = "agent-relay" }
  assert {
    condition     = length(replace(google_vpc_access_connector.this[0].name, "-", "--")) < 21
    error_message = "The normal hyphenated agent-relay prefix previously exceeded the connector's effective name limit."
  }
}

run "reserved_cluster_labels_cannot_be_overridden" {
  command = plan
  variables {
    labels = { environment = "wrong-environment", managed-by = "wrong-manager", team = "example-team" }
  }
  assert {
    condition     = google_container_cluster.this.resource_labels["environment"] == var.environment && google_container_cluster.this.resource_labels["managed-by"] == "terraform" && google_container_cluster.this.resource_labels["team"] == "example-team"
    error_message = "The final cluster labels must preserve customer labels while reserved identity labels cannot be overwritten or omitted."
  }
}
