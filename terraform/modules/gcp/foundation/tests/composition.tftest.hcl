mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
  mock_data "google_storage_project_service_account" {
    defaults = { email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com" }
  }
  mock_resource "google_compute_network" {
    defaults = { self_link = "https://www.googleapis.com/compute/v1/projects/example-project/global/networks/example-development" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email  = "example-runtime@example-project.iam.gserviceaccount.com"
      member = "serviceAccount:example-runtime@example-project.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name    = "example-project:us-central1:example-development-pg"
      private_ip_address = "10.50.0.5"
      server_ca_cert     = [{ cert = "public-offline-ca", common_name = "", create_time = "", expiration_time = "", sha1_fingerprint = "" }]
    }
  }
  mock_resource "google_cloudfunctions2_function" {
    defaults = { service_config = { uri = "https://example-offline.a.run.app" } }
  }
}
# random is the real local provider: Terraform 1.16 does not support mocked
# ephemeral resource types, even with count zero. The fixture explicitly sets
# admin_user.create=false, so it creates neither a password nor a secret value.
run "existing_data_capabilities_accept_foundation_contract" {
  command = apply
  module { source = "./tests/composition" }
  assert {
    condition     = output.contract.postgres.private_ip_address == "10.50.0.5" && output.contract.postgres.connection_name == "example-project:us-central1:example-development-pg" && toset(output.contract.postgres.databases) == toset(["relaycontrol", "relayhistory", "hoopdb"])
    error_message = "Existing PostgreSQL module must consume foundation private PSA network/range and preserve separate application databases."
  }
  assert {
    condition     = output.contract.foundation.network.functions_vpc_connector != null && output.contract.functions.function_uri == "https://example-offline.a.run.app" && output.contract.functions.events_topic_id != null && output.contract.objects.bucket_name == "example-development-sessions-offline-fixture"
    error_message = "Existing functions must receive foundation connector and composed bucket, keeping their own events topic."
  }
  assert {
    condition     = output.contract.objects.google_service_account_email == null && output.contract.objects.region == output.contract.foundation.identity.region && output.contract.postgres.admin_password_secret_id == null
    error_message = "Object access must use exact KSA Workload Identity; fixture must generate no database credentials."
  }
}
