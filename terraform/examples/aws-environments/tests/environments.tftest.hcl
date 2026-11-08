# Plans the whole example with every add-on on, so module wiring (including
# search <-> functions, which reference each other's outputs) stays acyclic.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/deployer/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  # Realistic values: OpenTofu fills computed attributes at plan time, and
  # the provider validates ARNs.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::relay-sessions", region = "us-west-2" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-west-2:111111111111:mock", url = "https://sqs.us-west-2.amazonaws.com/111111111111/mock" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-west-2:111111111111:function:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-west-2:111111111111:rule/mock" }
  }
  mock_resource "aws_opensearch_domain" {
    defaults = { arn = "arn:aws:es:us-west-2:111111111111:domain/mock", endpoint = "vpc-mock.us-west-2.es.amazonaws.com" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "mock.abc.us-west-2.rds.amazonaws.com"
      arn                = "arn:aws:rds:us-west-2:111111111111:db:mock"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds", kms_key_id = "", secret_status = "active" }]
    }
  }
}

mock_provider "random" {}

variables {
  account_id                  = "111111111111"
  region                      = "us-west-2"
  environment                 = "dev"
  private_subnet_ids          = ["subnet-a", "subnet-b"]
  database_security_group_ids = ["sg-db"]
  search_subnet_ids           = ["subnet-a"]
  search_security_group_ids   = ["sg-search"]
  search_master_user_arn      = "arn:aws:iam::111111111111:role/search-admin"
  eks_cluster_name            = "relay"
}

run "development_composition" {
  command = plan
  assert {
    condition     = output.verification.name_prefix == var.name_prefix && output.verification.environment_class == var.environment_class && output.verification.pippen == null && output.environment.name_prefix == var.name_prefix && output.verification.postgres.identifier == "agent-relay-dev-pg" && output.verification.postgres.master_username == "relay_admin"
    error_message = "The verifier must export the complete independently confirmed installation and exact database identity."
  }
  assert {
    condition     = output.environment.namespace == "agent-relay-dev" && output.verification.storage.prefix == "proofs/dev/"
    error_message = "Names must isolate the environment, account and region."
  }
  assert {
    condition = toset(keys(module.search.pod_identity_association_ids)) == toset([
      "indexer/relay/agent-relay-dev/agent-relay-search-indexer",
      "reader/relay/agent-relay-dev/agent-relay-session-read",
    ])
    error_message = "Search must use separate environment-scoped indexer and reader identities."
  }
}

run "custom_environment" {
  command = plan
  variables {
    environment       = "team-a"
    environment_class = "staging"
    search_subnet_ids = ["subnet-a", "subnet-b"]
  }
  assert {
    condition     = output.verification.storage.prefix == "proofs/team-a/" && output.environment.namespace == "agent-relay-team-a"
    error_message = "Environment labels are arbitrary slugs, not a fixed dev/prod enumeration."
  }
}

run "production_requires_three_zones" {
  command = plan
  variables { environment_class = "production" }
  expect_failures = [terraform_data.environment_contract]
}

run "production_cannot_disable_database_protection" {
  command = plan
  variables {
    environment_class   = "production"
    search_subnet_ids   = ["subnet-a", "subnet-b", "subnet-c"]
    deletion_protection = false
  }
  expect_failures = [terraform_data.environment_contract]
}

run "production_composition" {
  command = plan
  variables {
    environment       = "prod"
    environment_class = "production"
    search_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  }
  assert {
    condition     = output.environment.class == "production" && output.verification.storage.prefix == "proofs/prod/"
    error_message = "Production verification must use its own environment marker prefix."
  }
}

run "wrong_account_refused" {
  command = plan
  variables { account_id = "222222222222" }
  expect_failures = [terraform_data.environment_contract]
}

run "aurora_requires_explicit_version_and_class" {
  command = plan
  variables { postgres_engine_mode = "aurora" }
  expect_failures = [terraform_data.environment_contract]
}

run "pippen_wrong_session_refused" {
  command = plan
  variables {
    name_prefix = "pippen-sbx-ar"
    pippen      = { agent = "aws-proof", session_id = "wrong-session" }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "exact_pippen_lease_composes" {
  command = plan
  variables {
    name_prefix = "pippen-sbx-ar"
    pippen      = { agent = "aws-proof", session_id = "approved-session" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-approved-session" }
  }
  assert {
    condition     = output.verification.storage.prefix == "proofs/dev/"
    error_message = "The exact Pippen lease must be able to plan the environment."
  }
}

run "reserved_tags_refused" {
  command = plan
  variables { tags = { "pippen:sandbox" = "true" } }
  expect_failures = [var.tags]
}

run "overlong_resource_prefix_refused" {
  command = plan
  variables { name_prefix = "agent-relay-very-long" }
  expect_failures = [terraform_data.environment_contract]
}

run "lambda_composition" {
  command = plan
  assert {
    condition     = output.verification.pipeline.function_name == "agent-relay-dev-session-pipeline"
    error_message = "Lambda verification must export the exact installation function name, not just an arbitrary same-account ARN."
  }
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    enable_relayfile            = true
  }
  assert {
    condition     = length(module.pipeline) == 1 && output.application_contract.pipeline_runtime == "lambda" && output.application_contract.overlapping_pipeline_workers_must_be_disabled
    error_message = "Lambda mode must create its runtime and explicitly require overlapping worker stages to be disabled."
  }
  assert {
    condition     = alltrue([for component in ["cloudApi", "dashboard", "sessionsPipeline", "relayhistory", "relaycast", "relayauth", "relayfile"] : output.application_contract.components[component]]) && !output.application_contract.components.durableActors
    error_message = "The target suite includes control, dashboard, pipeline, History, Relaycast and optional Relayfile; a separate actor store is not required by the shared PostgreSQL target."
  }
  assert {
    condition     = !output.pipeline.activation_enabled && output.application_contract.hoopdb_bootstrap_profile == "shared-rds-schema-review-required"
    error_message = "Lambda must start inactive and require the reviewed shared-RDS schema bootstrap."
  }
}

run "mutable_null_s3_version_refused" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "null" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "runtime_cannot_be_search_admin" {
  command = plan
  variables { search_master_user_arn = "arn:aws:iam::111111111111:role/agent-relay-dev-session-pipeline" }
  expect_failures = [terraform_data.environment_contract]
}

run "storage_worker_cannot_be_search_admin" {
  command = plan
  variables { search_master_user_arn = "arn:aws:iam::111111111111:role/agent-relay-dev-sessions" }
  expect_failures = [terraform_data.environment_contract]
}

run "lambda_zip_must_be_immutable" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}

# Materialize only the local fence, so child-module data references are known
# during subsequent mock plans. Never apply the protected service resources.
run "external_contract_setup" {
  command = apply
  plan_options {
    target = [terraform_data.environment_contract]
  }
}

run "external_search_roles" {
  command = plan
  variables {
    existing_runtime_roles = {
      indexer_role_arn = "arn:aws:iam::111111111111:role/bootstrap/indexer"
      reader_role_arn  = "arn:aws:iam::111111111111:role/bootstrap/reader"
    }
  }
  assert {
    condition     = output.verification.search.indexer_role_arn == var.existing_runtime_roles.indexer_role_arn && output.verification.search.reader_role_arn == var.existing_runtime_roles.reader_role_arn && output.verification.search.lambda_role_arn == null
    error_message = "Verification must use the supplied roles even though the search module exports no authored roles."
  }
  assert {
    condition     = module.search.indexer_role_arn == null && module.search.reader_role_arn == null && length(module.search.pod_identity_association_ids) == 0
    error_message = "Search must use its existing create=false path without authoring runtime identities."
  }
  assert {
    condition     = toset(jsondecode(output.runtime_role_policy_json.indexer).Statement[0].Resource) == toset(["arn:aws:es:us-west-2:111111111111:domain/agent-relay-dev-search/*"]) && output.runtime_role_policy_json.pipeline == null
    error_message = "External bootstrap policy proposals must retain the exact environment domain scope and omit unused Lambda permissions."
  }
}

run "external_lambda_roles" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    existing_runtime_roles = {
      indexer_role_arn  = "arn:aws:iam::111111111111:role/bootstrap/indexer"
      reader_role_arn   = "arn:aws:iam::111111111111:role/bootstrap/reader"
      pipeline_role_arn = "arn:aws:iam::111111111111:role/bootstrap/pipeline"
    }
  }
  assert {
    condition     = module.pipeline[0].execution_role_arn == var.existing_runtime_roles.pipeline_role_arn && output.verification.search.lambda_role_arn == var.existing_runtime_roles.pipeline_role_arn && !output.pipeline.activation_enabled
    error_message = "External Lambda identity must reach both the function module and verifier, without activation."
  }
}

run "external_wrong_account" {
  command = plan
  variables {
    existing_runtime_roles = { indexer_role_arn = "arn:aws:iam::222222222222:role/indexer", reader_role_arn = "arn:aws:iam::111111111111:role/reader" }

  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_runtime_alias" {
  command = plan
  variables {
    existing_runtime_roles = { indexer_role_arn = "arn:aws:iam::111111111111:role/runtime", reader_role_arn = "arn:aws:iam::111111111111:role/runtime" }

  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_master_alias" {
  command = plan
  variables {
    existing_runtime_roles = { indexer_role_arn = "arn:aws:iam::111111111111:role/search-admin", reader_role_arn = "arn:aws:iam::111111111111:role/reader" }

  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_storage_alias" {
  command = plan
  variables {
    existing_runtime_roles = { indexer_role_arn = "arn:aws:iam::111111111111:role/agent-relay-dev-sessions", reader_role_arn = "arn:aws:iam::111111111111:role/reader" }

  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_pipeline_in_workers" {
  command = plan
  variables {
    existing_runtime_roles = { indexer_role_arn = "arn:aws:iam::111111111111:role/indexer", reader_role_arn = "arn:aws:iam::111111111111:role/reader", pipeline_role_arn = "arn:aws:iam::111111111111:role/pipeline" }

  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_missing_lambda_role" {
  command = plan
  variables {
    existing_runtime_roles      = { indexer_role_arn = "arn:aws:iam::111111111111:role/indexer", reader_role_arn = "arn:aws:iam::111111111111:role/reader" }
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "external_empty_search_identity" {
  command = plan
  variables { existing_runtime_roles = { indexer_role_arn = "", reader_role_arn = "arn:aws:iam::111111111111:role/reader" } }
  expect_failures = [var.existing_runtime_roles]
}

run "external_empty_pipeline_identity" {
  command = plan
  variables { existing_runtime_roles = { indexer_role_arn = "arn:aws:iam::111111111111:role/indexer", reader_role_arn = "arn:aws:iam::111111111111:role/reader", pipeline_role_arn = "" } }
  expect_failures = [var.existing_runtime_roles]
}

run "lambda_activation_requires_runtime_bindings" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    activate_lambda             = true
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "lambda_provider_and_tls_bindings" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    activate_lambda             = false
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  assert {
    condition = (
      output.lambda_shared_environment.SEARCH_INDEX_BACKEND == "opensearch" &&
      output.lambda_shared_environment.OPENSEARCH_REGION == "us-west-2" &&
      output.lambda_shared_environment.OPENSEARCH_INDEX == "agent-relay-dev-sessions-v2" &&
      output.lambda_shared_environment.SEARCH_INDEX_STATE_BACKEND_ID == "agent-relay-dev-sessions" &&
      output.lambda_shared_environment.READ_API_COMPLETE_SINCE == "epoch" &&
      output.lambda_shared_environment.SEARCH_INDEX_POSTGRES_SCHEMA == "search_index" &&
      output.lambda_shared_environment.SESSION_POSTGRES_TLS_PROFILE == "custom-ca" &&
      output.lambda_shared_environment.SESSION_POSTGRES_CA_FILE == "/var/task/assets/postgres-ca.pem" &&
      output.lambda_shared_environment.SESSION_POSTGRES_CA_SHA256 == var.lambda_runtime_bindings.postgres_ca_sha256 &&
      !contains(keys(output.lambda_shared_environment), "AWS_REGION") && !output.pipeline.activation_enabled
    )
    error_message = "Writer and reader must share explicit OpenSearch/projection/CA settings without a reserved AWS_REGION override; shared-database processing remains inactive."
  }
}

run "lambda_binding_environment_mismatch" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-prod-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "lambda_bindings_refused_in_worker_mode" {
  command = plan
  variables {
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "invalid_ca_digest_refused" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "not-a-reviewed-sha256"
    }
  }
  expect_failures = [var.lambda_runtime_bindings]
}

run "invalid_projection_identifier_refused" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "other tenant/backend"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.lambda_runtime_bindings]
}

run "negative_completeness_timestamp_refused" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "1969-12-31T23:59:59Z"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.lambda_runtime_bindings]
}

run "artifact_refuses_dotted_index" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    activate_lambda             = false
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions.v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.lambda_runtime_bindings]
}

run "artifact_refuses_202_character_index" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    activate_lambda             = false
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-${join("", [for i in range(186) : "s"])}"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.lambda_runtime_bindings]
}

run "artifact_accepts_201_character_index" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    activate_lambda             = false
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-${join("", [for i in range(185) : "s"])}"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  assert {
    condition     = length(output.lambda_shared_environment.OPENSEARCH_INDEX) == 201 && !output.pipeline.activation_enabled
    error_message = "The maximum index accepted by the matching private artifact must remain usable."
  }
}

run "shared_database_schema_bindings" {
  command = apply
  assert {
    condition     = output.postgres_service_bindings.control.database == output.verification.postgres.database && output.postgres_service_bindings.hoopdb.database == output.verification.postgres.database && output.postgres_service_bindings.relaycast.database == output.verification.postgres.database
    error_message = "Control, HoopDb and Relaycast must share the one RDS application database."
  }
  assert {
    condition     = alltrue([for binding in values(output.postgres_service_bindings) : binding.host == output.verification.postgres.host && binding.port == output.verification.postgres.port])
    error_message = "No service binding may silently point at another server."
  }
  assert {
    condition     = output.postgres_service_bindings.control.schema != output.postgres_service_bindings.hoopdb.schema && output.postgres_service_bindings.relaycast.schema == "relaycast" && !output.postgres_topology.application_sql_ready
    error_message = "Schemas must remain distinct and bindings must not imply completed SQL/runtime integration."
  }
}

run "explicit_new_install_database_name" {
  command = apply
  variables {
    application_database_name = "sharedapp"
  }
  assert {
    condition     = output.verification.postgres.database == "sharedapp" && alltrue([for binding in values(output.postgres_service_bindings) : binding.database == "sharedapp"])
    error_message = "The initial RDS database and all service bindings must agree on the explicitly reviewed name."
  }
}

run "maintenance_application_database_refused" {
  command = plan
  variables {
    application_database_name = "postgres"
  }
  expect_failures = [var.application_database_name]
}

run "shared_database_activation_refused_even_with_valid_bindings" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    activate_lambda             = true
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    lambda_runtime_bindings = {
      search_index       = "agent-relay-dev-sessions-v2"
      state_backend_id   = "agent-relay-dev-sessions"
      complete_since     = "epoch"
      postgres_ca_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "rds_internal_database_refused" {
  command = plan
  variables { application_database_name = "rdsadmin" }
  expect_failures = [var.application_database_name]
}
