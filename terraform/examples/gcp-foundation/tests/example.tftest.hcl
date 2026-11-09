mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
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
run "separate_foundation_state_contract" {
  command = apply
  assert {
    condition     = output.foundation.identity.project_id == var.project_id && output.foundation.identity.project_number == var.expected_project_number && output.foundation.identity.environment == var.expected_environment && output.foundation.network.functions_vpc_connector != null && output.foundation.gke.workload_pool == "example-project.svc.id.goog" && output.foundation.actor_host_profile == null && output.foundation.pipeline.redis == null
    error_message = "Thin root must expose non-secret foundation/data/application contracts without activating previews or generated credentials."
  }
}
run "root_environment_fence" {
  command = plan
  variables { expected_environment = "production" }
  expect_failures = [var.expected_environment]
}
