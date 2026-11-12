# Optional adoption of an EXISTING sessions bucket (sessions_bucket_import =
# true with sessions_bucket_name). Off by default: every for_each below is
# empty, so a default plan has no import and is unchanged.
#
# The bucket itself would conflict on create, so it is always imported. Its
# configuration resources are separate PUT-style objects that would otherwise
# plan as additional creates; importing them keeps the first plan to imports
# plus in-place updates. Every import ID is the bucket name. A configuration the
# existing bucket does not have (S3 has no bucket policy or lifecycle
# configuration until one is set) cannot be imported: list it in
# sessions_bucket_import_skip and it plans as a create instead.
locals {
  sessions_bucket_import_ids = var.sessions_bucket_import ? merge(
    { bucket = var.sessions_bucket_name },
    { for kind in setsubtract(local.sessions_bucket_import_configurations, var.sessions_bucket_import_skip) : kind => var.sessions_bucket_name },
  ) : {}
  sessions_bucket_import_configurations = toset(["public_access_block", "ownership_controls", "server_side_encryption_configuration", "versioning", "lifecycle_configuration", "policy"])
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "bucket" }
  to       = module.sessions_bucket.aws_s3_bucket.this
  id       = each.value
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "public_access_block" }
  to       = module.sessions_bucket.aws_s3_bucket_public_access_block.this
  id       = each.value
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "ownership_controls" }
  to       = module.sessions_bucket.aws_s3_bucket_ownership_controls.this
  id       = each.value
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "server_side_encryption_configuration" }
  to       = module.sessions_bucket.aws_s3_bucket_server_side_encryption_configuration.this
  id       = each.value
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "versioning" }
  to       = module.sessions_bucket.aws_s3_bucket_versioning.this
  id       = each.value
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "lifecycle_configuration" }
  to       = module.sessions_bucket.aws_s3_bucket_lifecycle_configuration.this
  id       = each.value
}

import {
  for_each = { for k, id in local.sessions_bucket_import_ids : k => id if k == "policy" }
  to       = module.sessions_bucket.aws_s3_bucket_policy.this
  id       = each.value
}
