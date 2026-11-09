locals {
  # AWS_REGION is supplied by Lambda itself and is a reserved environment key.
  # These values contain no credentials. The runtime obtains its DB URL from
  # the separately provisioned secret and uses its execution role for SigV4.
  lambda_shared_environment = var.lambda_runtime_bindings == null ? {} : {
    PIPELINE_RUNTIME              = "lambda"
    SEARCH_INDEX_BACKEND          = "opensearch"
    OPENSEARCH_ENDPOINT           = module.search.url
    OPENSEARCH_REGION             = var.region
    OPENSEARCH_INDEX              = var.lambda_runtime_bindings.search_index
    SEARCH_INDEX_STATE_BACKEND_ID = var.lambda_runtime_bindings.state_backend_id
    READ_API_COMPLETE_SINCE       = var.lambda_runtime_bindings.complete_since
    SEARCH_INDEX_POSTGRES_SCHEMA  = var.lambda_runtime_bindings.projection_schema
    SESSION_POSTGRES_TLS_PROFILE  = "custom-ca"
    SESSION_POSTGRES_CA_FILE      = "/var/task/assets/postgres-ca.pem"
    SESSION_POSTGRES_CA_SHA256    = var.lambda_runtime_bindings.postgres_ca_sha256
  }
}
