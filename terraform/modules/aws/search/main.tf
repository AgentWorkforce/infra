data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # Select only non-secret attributes; concatenating entire provider objects
  # propagates the schema's password sensitivity into unrelated public outputs.
  domain = {
    domain_name        = one(concat(aws_opensearch_domain.this[*].domain_name, aws_opensearch_domain.disposable[*].domain_name))
    arn                = one(concat(aws_opensearch_domain.this[*].arn, aws_opensearch_domain.disposable[*].arn))
    endpoint           = one(concat(aws_opensearch_domain.this[*].endpoint, aws_opensearch_domain.disposable[*].endpoint))
    dashboard_endpoint = one(concat(aws_opensearch_domain.this[*].dashboard_endpoint, aws_opensearch_domain.disposable[*].dashboard_endpoint))
  }
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
  domain_arn = "arn:${local.partition}:es:${local.region}:${local.account_id}:domain/${var.domain_name}"
  az_count   = length(var.subnet_ids)
  # Smallest multiple of the AZ count that is at least 3.
  # max() only guards enabled = false, which passes no subnets.
  instance_count = coalesce(var.instance_count, local.az_count * ceil(3 / max(local.az_count, 1)))

  create_roles = var.workload_roles.create
  role_prefix  = coalesce(var.workload_roles.name_prefix, var.domain_name)
  oidc_host    = var.workload_roles.oidc_provider_arn == null ? null : element(split("oidc-provider/", var.workload_roles.oidc_provider_arn), 1)

  # Index and bulk writes, index/template management (FGAC narrows this
  # further to the mapped OpenSearch role). Searches use GET and POST
  # (_search, _msearch, _count); the reader has no PUT, DELETE or PATCH.
  actions = {
    indexer = ["es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete", "es:ESHttpPatch"]
    reader  = ["es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost"]
  }

  policies = {
    for role, actions in local.actions : role => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid      = "OpenSearchHttp"
        Effect   = "Allow"
        Action   = actions
        Resource = ["${local.domain_arn}/*"]
      }]
    })
  }

  # Separate from `policies`: indexer_policy_json also feeds the Lambda pipeline,
  # which holds its own bucket grants. Each statement group is its own
  # conditional list so no conditional unifies differently shaped statements.
  sessions_read_policy = var.sessions_bucket_read == null ? null : jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ListSessionsBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.sessions_bucket_read.bucket_arn]
      }],
      [{
        Sid      = "ReadSessionObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${var.sessions_bucket_read.bucket_arn}/*"]
      }],
      var.sessions_bucket_read.kms_key_arn == null ? [] : [{
        Sid       = "DecryptSessionsBucketKey"
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = [var.sessions_bucket_read.kms_key_arn]
        Condition = { StringEquals = { "kms:ViaService" = "s3.${local.region}.${data.aws_partition.current.dns_suffix}" } }
      }],
    )
  })

  roles = var.enabled && local.create_roles ? {
    indexer = { service_accounts = var.workload_roles.indexer_service_accounts }
    reader  = { service_accounts = var.workload_roles.reader_service_accounts }
  } : {}

  workload_principal_arns = [for r in aws_iam_role.workload : r.arn]

  access_principals = distinct(concat(local.workload_principal_arns, var.additional_principal_arns, [var.master_user_arn]))

  log_types = var.enabled ? toset(var.log_publishing) : toset([])
}

# ---------------------------------------------------------------------------
# Workload roles (indexer, reader)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "workload" {
  for_each = local.roles

  name                 = "${local.role_prefix}-${each.key}"
  path                 = var.workload_roles.path
  permissions_boundary = var.workload_roles.permissions_boundary_arn
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "EksPodIdentity"
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
      }],
      local.oidc_host == null || length(each.value.service_accounts) == 0 ? [] : [{
        Sid       = "Irsa"
        Effect    = "Allow"
        Principal = { Federated = var.workload_roles.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_host}:aud" = "sts.amazonaws.com"
            "${local.oidc_host}:sub" = [for sa in each.value.service_accounts : "system:serviceaccount:${sa.namespace}:${sa.service_account}"]
          }
        }
      }],
    )
  })
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.roles

  name   = "opensearch-${var.domain_name}"
  role   = aws_iam_role.workload[each.key].id
  policy = local.policies[each.key]
}

# Its own resource, not a statement on the policy above: existing roles and
# their OpenSearch policy stay untouched, and each inline policy is individually
# managed so creation_mode.py can admit the role's inline_policy read-back.
resource "aws_iam_role_policy" "sessions_read" {
  for_each = var.sessions_bucket_read == null ? toset([]) : toset(keys(local.roles))

  name   = "sessions-read-${var.domain_name}"
  role   = aws_iam_role.workload[each.key].id
  policy = local.sessions_read_policy
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = merge([
    for role, cfg in local.roles : {
      for sa in cfg.service_accounts : "${role}/${sa.cluster_name}/${sa.namespace}/${sa.service_account}" => merge(sa, { role = role })
      if sa.cluster_name != null
    }
  ]...)

  cluster_name    = each.value.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.value.role].arn
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_338:Retention is the customer's choice (log_retention_days, default 30).
  for_each = local.log_types

  name              = "/aws/opensearch/${var.domain_name}/${lower(each.key)}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_resource_policy" "this" {
  count = var.create_log_resource_policy && length(local.log_types) > 0 ? 1 : 0

  policy_name = "opensearch-${var.domain_name}"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OpenSearchLogs"
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = [for g in aws_cloudwatch_log_group.this : "${g.arn}:*"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = local.domain_arn }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# Domain
# ---------------------------------------------------------------------------

# Persist the creation mode. This blocks ordinary flips only after correct
# enrollment; reviewed runners additionally check native prior-state history.
# No prevent_destroy here: an owned disposable lifecycle must retire normally.
# Not gated by `enabled`: it holds no AWS object, and a later enablement then
# admits as the reviewed fresh-retry (marker unchanged, domain created).
resource "terraform_data" "creation_mode" {
  input = var.disposable
  lifecycle {
    ignore_changes = [input]
    postcondition {
      condition     = self.input == var.disposable
      error_message = "OpenSearch creation mode cannot change for an enrolled state."
    }
  }
}

# Preserve the existing protected domain's state address without recreation.
moved {
  from = aws_opensearch_domain.this
  to   = aws_opensearch_domain.this[0]
}

resource "aws_opensearch_domain" "this" {
  count = var.enabled && !var.disposable ? 1 : 0
  #checkov:skip=CKV_AWS_248:security_group_ids is a required input; the default security group is never used implicitly.
  #checkov:skip=CKV_AWS_317:Audit logs need the security plugin's audit config; add AUDIT_LOGS to log_publishing to enable them.
  domain_name    = var.domain_name
  engine_version = var.engine_version

  cluster_config {
    instance_type                 = var.instance_type
    instance_count                = local.instance_count
    dedicated_master_enabled      = var.dedicated_master_enabled
    dedicated_master_type         = var.dedicated_master_enabled ? var.dedicated_master_type : null
    dedicated_master_count        = var.dedicated_master_enabled ? var.dedicated_master_count : null
    multi_az_with_standby_enabled = var.multi_az_with_standby_enabled
    zone_awareness_enabled        = local.az_count > 1

    dynamic "zone_awareness_config" {
      for_each = local.az_count > 1 ? [1] : []
      content {
        availability_zone_count = local.az_count
      }
    }
  }

  vpc_options {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  ebs_options {
    ebs_enabled = true
    volume_type = var.ebs_volume_type
    volume_size = var.ebs_volume_size
    iops        = var.ebs_iops
    throughput  = var.ebs_throughput
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = var.tls_security_policy
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = false
    master_user_options {
      master_user_arn = var.master_user_arn
    }
  }

  snapshot_options {
    automated_snapshot_start_hour = var.automated_snapshot_start_hour
  }

  software_update_options {
    auto_software_update_enabled = var.auto_software_update_enabled
  }

  off_peak_window_options {
    enabled = true
    off_peak_window {
      window_start_time {
        hours   = var.off_peak_window_start.hours
        minutes = var.off_peak_window_start.minutes
      }
    }
  }

  dynamic "log_publishing_options" {
    for_each = aws_cloudwatch_log_group.this
    content {
      log_type                 = log_publishing_options.key
      cloudwatch_log_group_arn = log_publishing_options.value.arn
    }
  }

  advanced_options = var.advanced_options

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.instance_count % local.az_count == 0
      error_message = "instance_count must be a multiple of the number of subnet_ids (AZs)."
    }
    precondition {
      condition     = !var.multi_az_with_standby_enabled || (local.az_count == 3 && var.dedicated_master_enabled && var.dedicated_master_count == 3 && local.instance_count % 3 == 0)
      error_message = "Multi-AZ with Standby needs three subnets (AZs), three dedicated masters and a multiple of three data nodes."
    }
    # Default domains retain the literal guard, including when count changes.
    # A protected domain cannot be converted to disposable by toggling the input.
    prevent_destroy = true
  }

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}

resource "aws_opensearch_domain" "disposable" {
  count = var.enabled && var.disposable ? 1 : 0
  #checkov:skip=CKV_AWS_248:security_group_ids is a required input; the default security group is never used implicitly.
  #checkov:skip=CKV_AWS_317:Audit logs need the security plugin's audit config; add AUDIT_LOGS to log_publishing to enable them.
  domain_name    = var.domain_name
  engine_version = var.engine_version

  cluster_config {
    instance_type                 = var.instance_type
    instance_count                = local.instance_count
    dedicated_master_enabled      = var.dedicated_master_enabled
    dedicated_master_type         = var.dedicated_master_enabled ? var.dedicated_master_type : null
    dedicated_master_count        = var.dedicated_master_enabled ? var.dedicated_master_count : null
    multi_az_with_standby_enabled = var.multi_az_with_standby_enabled
    zone_awareness_enabled        = local.az_count > 1

    dynamic "zone_awareness_config" {
      for_each = local.az_count > 1 ? [1] : []
      content {
        availability_zone_count = local.az_count
      }
    }
  }

  vpc_options {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  ebs_options {
    ebs_enabled = true
    volume_type = var.ebs_volume_type
    volume_size = var.ebs_volume_size
    iops        = var.ebs_iops
    throughput  = var.ebs_throughput
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = var.tls_security_policy
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = false
    master_user_options {
      master_user_arn = var.master_user_arn
    }
  }

  snapshot_options {
    automated_snapshot_start_hour = var.automated_snapshot_start_hour
  }

  software_update_options {
    auto_software_update_enabled = var.auto_software_update_enabled
  }

  off_peak_window_options {
    enabled = true
    off_peak_window {
      window_start_time {
        hours   = var.off_peak_window_start.hours
        minutes = var.off_peak_window_start.minutes
      }
    }
  }

  dynamic "log_publishing_options" {
    for_each = aws_cloudwatch_log_group.this
    content {
      log_type                 = log_publishing_options.key
      cloudwatch_log_group_arn = log_publishing_options.value.arn
    }
  }

  advanced_options = var.advanced_options

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.instance_count % local.az_count == 0
      error_message = "instance_count must be a multiple of the number of subnet_ids (AZs)."
    }
    precondition {
      condition     = !var.multi_az_with_standby_enabled || (local.az_count == 3 && var.dedicated_master_enabled && var.dedicated_master_count == 3 && local.instance_count % 3 == 0)
      error_message = "Multi-AZ with Standby needs three subnets (AZs), three dedicated masters and a multiple of three data nodes."
    }
    # Explicitly disposable from creation; never use for durable/customer data.
    # Normal retirement remains a reviewed Terraform destroy, with state intact.
    prevent_destroy = false
  }

  depends_on = [aws_cloudwatch_log_resource_policy.this]
}

# A separate resource so the policy can name the workload roles without a
# create-time cycle. Every request is also checked by fine-grained access
# control, so IAM here is the outer gate only.
resource "aws_opensearch_domain_policy" "this" {
  count = var.enabled ? 1 : 0

  domain_name = local.domain.domain_name
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowListedPrincipals"
      Effect    = "Allow"
      Principal = { AWS = local.access_principals }
      Action    = "es:ESHttp*"
      Resource  = "${local.domain_arn}/*"
    }]
  })
}

# Preserve the existing domain policy's state address without recreation.
moved {
  from = aws_opensearch_domain_policy.this
  to   = aws_opensearch_domain_policy.this[0]
}
