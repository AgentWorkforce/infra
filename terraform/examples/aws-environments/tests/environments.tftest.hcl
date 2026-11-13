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
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000", key_id = "00000000-0000-4000-8000-000000000000" }
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
    condition     = output.environment.namespace == "agent-relay-dev" && output.verification.namespace == "agent-relay-dev" && output.verification.storage.prefix == "proofs/dev/"
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
    condition     = alltrue([for component in ["cloudApi", "dashboard", "sessionsPipeline", "relaycast", "relayfile"] : output.application_contract.components[component]]) && !output.application_contract.components.durableActors && !output.application_contract.components.relayauth && !contains(keys(output.application_contract.components), "relayhistory")
    error_message = "The target suite includes control, dashboard, pipeline History capability, Relaycast and optional Relayfile; RelayAuth and actor stores are not required and there is no standalone History component."
  }
  assert {
    condition     = !output.pipeline.activation_enabled && output.application_contract.hoopdb_bootstrap_profile == "dedicated-rds-database-review-required"
    error_message = "Lambda must start inactive and require the reviewed dedicated-database RDS bootstrap."
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
run "sessions_bucket_read_is_on_by_default" {
  command = plan
  assert {
    condition = toset(flatten([for s in jsondecode(module.search.sessions_read_policy_json).Statement : s.Resource])) == toset([
      "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions",
      "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions/*",
    ])
    error_message = "By default the search roles read only this environment's bucket; the AWS-managed key needs no key grant."
  }
  assert {
    condition     = toset(flatten([for s in jsondecode(output.runtime_role_policy_json.sessions_read).Statement : s.Action])) == toset(["s3:ListBucket", "s3:GetObject"])
    error_message = "The default grant must be read-only and publish no kms:Decrypt for the AWS-managed key."
  }
}

run "sessions_bucket_read_opt_out_adds_nothing" {
  command = plan
  variables { search_sessions_bucket_read_enabled = false }
  assert {
    condition     = module.search.sessions_read_policy_json == null && !contains(keys(output.runtime_role_policy_json), "sessions_read")
    error_message = "Opting out must add no sessions read policy."
  }
}

run "external_contract_setup" {
  command = apply
  plan_options {
    target = [terraform_data.environment_contract]
  }
}

run "sessions_bucket_read_is_scoped" {
  command = plan
  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555"
    search_sessions_bucket_read = {
      bucket_arn  = "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions"
      kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555"
    }
  }
  assert {
    condition = toset(flatten([for s in jsondecode(module.search.sessions_read_policy_json).Statement : s.Resource])) == toset([
      "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions",
      "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions/*",
      "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555",
    ])
    error_message = "The search roles may read only this environment's bucket and key."
  }
  assert {
    condition     = toset(flatten([for s in jsondecode(output.runtime_role_policy_json.sessions_read).Statement : s.Action])) == toset(["s3:ListBucket", "s3:GetObject", "kms:Decrypt"])
    error_message = "The root must publish exactly the read-only actions."
  }
}

run "sessions_bucket_read_default_uses_the_environment_key" {
  command = plan
  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555"
  }
  assert {
    condition = toset(flatten([for s in jsondecode(module.search.sessions_read_policy_json).Statement : s.Resource])) == toset([
      "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions",
      "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions/*",
      "arn:aws:kms:us-west-2:111111111111:key/11111111-2222-3333-4444-555555555555",
    ])
    error_message = "The default grant must decrypt only with the environment's customer-managed key."
  }
}

run "sessions_bucket_read_explicit_conflicts_with_opt_out" {
  command = plan
  variables {
    search_sessions_bucket_read_enabled = false
    search_sessions_bucket_read         = { bucket_arn = "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions" }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "sessions_bucket_read_refuses_another_bucket" {
  command = plan
  variables {
    search_sessions_bucket_read = { bucket_arn = "arn:aws:s3:::some-other-bucket" }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "sessions_bucket_read_refuses_another_key" {
  command = plan
  variables {
    search_sessions_bucket_read = {
      bucket_arn  = "arn:aws:s3:::agent-relay-dev-111111111111-us-west-2-sessions"
      kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/99999999-2222-3333-4444-555555555555"
    }
  }
  expect_failures = [terraform_data.environment_contract]
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
    error_message = "Writer and reader must share explicit OpenSearch/projection/CA settings without a reserved AWS_REGION override; per-service database processing remains inactive."
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

run "separate_service_database_bindings" {
  command = apply
  assert {
    condition     = output.postgres_service_bindings.control.database == output.verification.postgres.database && output.postgres_service_bindings.hoopdb.database == "hoopdb" && output.postgres_service_bindings.relaycast.database == "relaycast"
    error_message = "Control, HoopDb and Relaycast must use separate databases on one RDS instance."
  }
  assert {
    condition     = alltrue([for binding in values(output.postgres_service_bindings) : binding.host == output.verification.postgres.host && binding.port == output.verification.postgres.port])
    error_message = "No service binding may silently point at another server."
  }
  assert {
    condition     = output.postgres_service_bindings.control.schema != output.postgres_service_bindings.hoopdb.schema && output.postgres_service_bindings.relaycast.schema == "public" && !output.postgres_topology.application_sql_ready
    error_message = "Service bindings must keep canonical schemas and must not imply completed SQL/runtime integration."
  }
}

run "explicit_new_install_database_name" {
  command = apply
  variables {
    application_database_name = "sharedapp"
  }
  assert {
    condition     = output.verification.postgres.database == "sharedapp" && output.postgres_service_bindings.control.database == "sharedapp" && output.postgres_service_bindings.hoopdb.database == "hoopdb" && output.postgres_service_bindings.relaycast.database == "relaycast"
    error_message = "Changing the initial Control database name must not rename other service databases."
  }
}

run "maintenance_application_database_refused" {
  command = plan
  variables {
    application_database_name = "postgres"
  }
  expect_failures = [var.application_database_name]
}

run "application_activation_refused_even_with_valid_bindings" {
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

run "existing_service_database_names_preserved" {
  command = apply
  variables {
    service_database_names = { hoopdb = "existing_pipeline", relaycast = "existing_cast", relayfile = "existing_files" }
  }
  assert {
    condition     = output.postgres_service_bindings.control.database == "relaycontrol" && output.postgres_service_bindings.hoopdb.database == "existing_pipeline" && output.postgres_service_bindings.relaycast.database == "existing_cast" && output.postgres_service_bindings.relayfile.database == "existing_files"
    error_message = "Database binding overrides must preserve existing service names without changing Control's initial database."
  }
}

run "service_database_collides_with_control_refused" {
  command = plan
  variables { service_database_names = { hoopdb = "relaycontrol", relaycast = "relaycast", relayfile = "relayfile" } }
  expect_failures = [var.service_database_names]
}

run "desktop_feed_off_by_default" {
  command = plan

  assert {
    condition     = length(module.desktop_feed) == 0 && output.desktop_feed == null
    error_message = "The Desktop feed creates nothing unless desktop_feed is set."
  }
}

run "desktop_feed_binds_control_in_the_environment_namespace" {
  variables {
    desktop_feed = { profiles = ["p1", "p2"] }
  }

  assert {
    condition = output.desktop_feed.control_env == {
      SELFHOST_DESKTOP_FEED_SIGNER          = "awskms"
      SELFHOST_DESKTOP_FEED_STORAGE         = "s3"
      SELFHOST_DESKTOP_FEED_KMS_REGION      = "us-west-2"
      SELFHOST_DESKTOP_FEED_KMS_KEY_ALIASES = jsonencode({ p1 = "alias/agent-relay-dev-desktop-feed-p1", p2 = "alias/agent-relay-dev-desktop-feed-p2" })
      SELFHOST_DESKTOP_FEED_S3_BUCKET       = module.desktop_feed[0].control_env.SELFHOST_DESKTOP_FEED_S3_BUCKET
      SELFHOST_DESKTOP_FEED_S3_REGION       = "us-west-2"
      SELFHOST_DESKTOP_FEED_S3_PREFIX       = "desktop-feed"
    }
    error_message = "desktop_feed.control_env must map directly to Control's SELFHOST_DESKTOP_FEED_* settings."
  }
  assert {
    condition     = output.desktop_feed.namespace == "agent-relay-dev" && output.desktop_feed.service_account == "relay-control" && keys(module.desktop_feed[0].pod_identity_association_ids) == ["relay/agent-relay-dev/relay-control"]
    error_message = "Control's Pod Identity binds the relay-control ServiceAccount the profile overlays render, in the environment namespace."
  }
  assert {
    condition     = length(output.desktop_feed.key_arns) == 2 && output.desktop_feed.role_arn != null
    error_message = "One key per profile and a Control role are created."
  }
}

run "desktop_feed_under_a_pippen_lease_with_overrides" {
  command = plan

  variables {
    name_prefix  = "pippen-sbx-ar"
    pippen       = { agent = "aws-proof", session_id = "approved-session" }
    desktop_feed = { profiles = ["p1"], service_account = "custom-control", prefix = "feeds/dev" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-approved-session" }
  }

  assert {
    condition     = output.desktop_feed.control_env.SELFHOST_DESKTOP_FEED_S3_PREFIX == "feeds/dev" && output.desktop_feed.control_env.SELFHOST_DESKTOP_FEED_KMS_KEY_ALIASES == jsonencode({ p1 = "alias/pippen-sbx-ar-dev-desktop-feed-p1" })
    error_message = "The prefix and Pippen-prefixed aliases pass through."
  }
  assert {
    condition     = output.desktop_feed.service_account == "custom-control"
    error_message = "An explicit Control ServiceAccount overrides the release default."
  }
}

run "history_upload_has_distinct_native_and_control_bindings" {
  command = apply
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge" }
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.history_control) == 1 && aws_eks_pod_identity_association.history_control[0].service_account == "relay-control" && aws_eks_pod_identity_association.history_consumer[0].service_account == "native-ingest-edge"
    error_message = "Control and native consumer have explicit independent Pod Identity bindings."
  }
  assert {
    condition     = output.history_upload.control_values.historyUpload.mode == "off" && output.history_upload.control_values.historyUpload.keyRoot == "96bulls"
    error_message = "Provisioning upload resources must not activate the feature."
  }
}

run "history_upload_reuses_desktop_feed_control_identity" {
  command = apply
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge" }
    desktop_feed   = { profiles = ["kindtest"] }
  }
  assert {
    condition     = length(aws_eks_pod_identity_association.history_control) == 0 && length(module.desktop_feed[0].pod_identity_association_ids) == 1 && output.history_upload.control_role_arn == module.desktop_feed[0].role_arn
    error_message = "EKS permits one role per ServiceAccount: direct uploads reuse the feed role."
  }
}

run "history_upload_feed_service_account_mismatch_refuses" {
  command = plan
  variables {
    kms_key_arn    = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    history_upload = { consumer_service_account = "native-ingest-edge" }
    desktop_feed   = { profiles = ["kindtest"], service_account = "other-control" }
  }
  expect_failures = [aws_iam_role.history_consumer]
}
