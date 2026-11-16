# A bucket for the S3 upload ledger's own objects (relayhistory-pipeline
# src/session-ingest/ledger-store.ts, docs/ledger-relocation.md), in the ingest
# edge's region, and the grants of the two roles that use it. The Locker bucket,
# its policies and the roles' other grants are untouched.
#
# Ledger objects: <key_root>/.admission-inbox/<org>/v1/ws=*/m=*/ledger/** and the
# ledger-home marker <key_root>/.ledger/fence-authority/.ledger-home.json. The
# edge also proves conditional writes at startup under <key_root>/.admission-probe/.
locals {
  bucket_arn = "arn:aws:s3:::${var.bucket_name}" # known at plan
  objects    = "${local.bucket_arn}/${var.key_root}/*"
  ledger     = "${local.bucket_arn}/${var.key_root}/.admission-inbox/*/ledger/*"
  rearm_done = "${local.bucket_arn}/${var.key_root}/.admission-inbox/*/ledger/rearm/*.done/*"
  rearm_bad  = "${local.bucket_arn}/${var.key_root}/.admission-inbox/*/ledger/rearm/*.corrupt/*"
  home       = "${local.bucket_arn}/${var.key_root}/.ledger/fence-authority/.ledger-home.json"
  kms        = var.sse_kms_key_arn != null
  sweeper    = var.rearm_sweeper_role_name != null
  kms_via    = local.kms ? "s3.${split(":", var.sse_kms_key_arn)[3]}.amazonaws.com" : null
  key_via_s3 = local.kms ? [{
    Sid       = "LedgerKeyViaS3"
    Effect    = "Allow"
    Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
    Resource  = var.sse_kms_key_arn
    Condition = { StringEquals = { "kms:ViaService" = local.kms_via } }
  }] : []
}

resource "aws_s3_bucket" "ledger" {
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_ownership_controls" "ledger" {
  bucket = aws_s3_bucket.ledger.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "ledger" {
  bucket                  = aws_s3_bucket.ledger.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "ledger" {
  bucket = aws_s3_bucket.ledger.id
  versioning_configuration { status = "Enabled" }
}

# The edge sends no encryption header, so this default applies to every object.
resource "aws_s3_bucket_server_side_encryption_configuration" "ledger" {
  bucket = aws_s3_bucket.ledger.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.sse_kms_key_arn
    }
    bucket_key_enabled = local.kms
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ledger" {
  bucket     = aws_s3_bucket.ledger.id
  depends_on = [aws_s3_bucket_versioning.ledger]
  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = var.noncurrent_version_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_policy" "ledger" {
  bucket     = aws_s3_bucket.ledger.id
  depends_on = [aws_s3_bucket_public_access_block.ledger]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

data "aws_iam_role" "consumer" {
  name = var.consumer_role_name
}

data "aws_iam_role" "rearm_sweeper" {
  count = local.sweeper ? 1 : 0
  name  = var.rearm_sweeper_role_name
}

# The edge: every ledger claim, commit and control, the startup conditional-write
# probe (create, CAS, delete) and the offline relocation Job, which runs as the
# edge's ServiceAccount.
resource "aws_iam_role_policy" "consumer" {
  name = "ingest-ledger-bucket"
  role = data.aws_iam_role.consumer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      # Unconditioned: a missing key must answer 404 (create-only reads), and the routed store lists.
      { Sid = "LedgerList", Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.bucket_arn },
      { Sid = "LedgerObjects", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = local.objects },
      {
        Sid      = "LedgerNoHistoryNoAdmin"
        Effect   = "Deny"
        Action   = ["s3:DeleteObjectVersion", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutLifecycleConfiguration", "s3:PutEncryptionConfiguration", "s3:PutBucketVersioning", "s3:DeleteBucket"]
        Resource = [local.bucket_arn, "${local.bucket_arn}/*"]
      },
    ], local.key_via_s3)
  })
}

# The sweeper: lists and reads markers, completion records and ownership stubs,
# reads the home marker, and creates completion and corrupt records. It erases
# nothing here (the canonical layout stays in the Locker bucket).
resource "aws_iam_role_policy" "rearm_sweeper" {
  count = local.sweeper ? 1 : 0
  name  = "ingest-ledger-bucket"
  role  = data.aws_iam_role.rearm_sweeper[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "LedgerList", Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.bucket_arn },
      { Sid = "LedgerReads", Effect = "Allow", Action = ["s3:GetObject"], Resource = [local.ledger, local.home] },
      { Sid = "LedgerRearmRecords", Effect = "Allow", Action = ["s3:PutObject"], Resource = [local.rearm_done, local.rearm_bad] },
    ], local.key_via_s3)
  })
}
