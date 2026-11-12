# sessions_bucket_unmanaged: leave an existing bucket's policy and/or lifecycle
# configuration alone (nothing imported, created or replaced). Off by default:
# with an empty list nothing here plans.
#
# history_upload's inbox wall lives in the bucket policy: a Deny for every
# principal but the consumer role on reading/deleting .upload-inbox objects,
# and a Deny on any overwriting PutObject. IAM identity policies cannot
# express "everyone but the consumer", so the wall cannot move out of the
# bucket policy. Terraform does not write it into an unmanaged policy either
# (no read-merge-write: that would still own the whole document and race the
# other owner). Instead this root refuses to plan history_upload unless the
# LIVE bucket policy already contains every wall statement, compared
# statement-by-statement after normalising AWS's single-item lists. The
# statements to merge are in the error, and in output.history_upload after
# apply. The check runs on every plan, so a later removal is caught too.
locals {
  unmanaged_policy           = contains(var.sessions_bucket_unmanaged, "policy")
  history_consumer_role_arn  = "arn:aws:iam::${var.account_id}:role${local.role_path}${local.name}-history-consumer"
  sessions_policy_wall_check = local.unmanaged_policy && local.history_upload_enabled

  # One canonical string per statement: AWS may return one-item lists as
  # strings and reorders lists and keys.
  sessions_policy_wall_required = [for s in module.sessions_bucket.upload_wall_statements : jsonencode({
    Sid       = try(s.Sid, "")
    Effect    = s.Effect
    Principal = try(s.Principal == "*", false) || try(s.Principal.AWS == "*", false) ? "*" : jsonencode(try(s.Principal, null))
    Action    = sort(distinct(flatten([try(s.Action, [])])))
    Resource  = sort(distinct(flatten([try(s.Resource, [])])))
    Condition = { for op, kv in try(s.Condition, {}) : op => { for k, v in kv : k => sort(distinct(flatten([v]))) } }
  })]
  sessions_policy_wall_live = !local.sessions_policy_wall_check ? [] : [for s in try(jsondecode(data.aws_s3_bucket_policy.sessions_existing[0].policy).Statement, []) : jsonencode({
    Sid       = try(s.Sid, "")
    Effect    = s.Effect
    Principal = try(s.Principal == "*", false) || try(s.Principal.AWS == "*", false) ? "*" : jsonencode(try(s.Principal, null))
    Action    = sort(distinct(flatten([try(s.Action, [])])))
    Resource  = sort(distinct(flatten([try(s.Resource, [])])))
    Condition = { for op, kv in try(s.Condition, {}) : op => { for k, v in kv : k => sort(distinct(flatten([v]))) } }
  })]
  sessions_policy_wall_missing = [for i, s in local.sessions_policy_wall_required : module.sessions_bucket.upload_wall_statements[i].Sid if !contains(local.sessions_policy_wall_live, s)]
}

data "aws_s3_bucket_policy" "sessions_existing" {
  count  = local.sessions_policy_wall_check ? 1 : 0
  bucket = local.sessions_bucket_name
}

resource "terraform_data" "sessions_policy_wall" {
  count = local.sessions_policy_wall_check ? 1 : 0
  input = { bucket = local.sessions_bucket_name, statements = local.sessions_policy_wall_required }

  lifecycle {
    precondition {
      condition     = length(local.sessions_policy_wall_missing) == 0
      error_message = "history_upload with an unmanaged bucket policy requires the live policy of ${local.sessions_bucket_name} to already contain the upload inbox wall. Missing: ${join(", ", local.sessions_policy_wall_missing)}. Merge these exact statements by hand, then plan again: ${jsonencode(module.sessions_bucket.upload_wall_statements)}"
    }
  }
}
