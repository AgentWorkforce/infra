# A private bucket of installer downloads behind CloudFront. Every download
# needs a CloudFront signed URL; the bucket itself is never public and answers
# only CloudFront (origin access control). The private signing key is created
# and kept by the operator in a secret manager; only its public half is here.
#
# Objects live at <origin_prefix>/<channel>/..., and the distribution serves
# them with <origin_prefix> as its root.
locals {
  bucket_arn  = "arn:aws:s3:::${var.bucket_name}" # known at plan
  origin_arn  = "${local.bucket_arn}/${var.origin_prefix}/*"
  certificate = var.domain_name != null
  use_domain  = var.domain_name != null && var.attach_domain
}

resource "aws_s3_bucket" "downloads" {
  #checkov:skip=CKV2_AWS_62:Nothing consumes download events.
  #checkov:skip=CKV_AWS_18:Access logs need a separate target bucket; add one outside this example if required.
  #checkov:skip=CKV_AWS_144:Installers are rebuilt from source; cross-region replication needs a second region and bucket.
  #checkov:skip=CKV_AWS_145:SSE-S3 is enough for installers that are meant to be downloaded; SSE-KMS would need extra key policy for CloudFront.
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_ownership_controls" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "downloads" {
  bucket                  = aws_s3_bucket.downloads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "downloads" {
  bucket     = aws_s3_bucket.downloads.id
  depends_on = [aws_s3_bucket_versioning.downloads]
  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = var.noncurrent_version_days }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# CloudFront may read one prefix and nothing else. There is no s3:ListBucket
# grant on purpose: a missing key answers 403, not 404, so a visitor cannot tell
# a missing file from a forbidden one.
resource "aws_s3_bucket_policy" "downloads" {
  bucket     = aws_s3_bucket.downloads.id
  depends_on = [aws_s3_bucket_public_access_block.downloads]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AllowCloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = local.origin_arn
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.downloads.arn } }
      },
    ]
  })
}

resource "aws_cloudfront_origin_access_control" "downloads" {
  name                              = coalesce(var.origin_access_control_name, "${var.bucket_name}-oac")
  description                       = "Signed S3 reads for ${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Public keys have fixed names: a key's name and PEM cannot change in place, so
# an existing key is imported under its own name and a rotation adds a second
# entry. The key group lists every key.
resource "aws_cloudfront_public_key" "signing" {
  for_each = var.signing_public_keys

  name        = each.key
  comment     = "Signed-URL verification key for ${var.bucket_name}"
  encoded_key = each.value
}

resource "aws_cloudfront_key_group" "signing" {
  name    = coalesce(var.key_group_name, "${var.bucket_name}-signers")
  comment = "Keys that may sign downloads for ${var.bucket_name}"
  items   = [for k in aws_cloudfront_public_key.signing : k.id]
}

# The managed policy that never caches, so a replaced object is served on the next request.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# The certificate, in us-east-1, validated by a DNS record the operator adds at
# the DNS host (not Route 53, so nothing here creates it).
resource "aws_acm_certificate" "downloads" {
  count    = local.certificate ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = var.tags

  lifecycle { create_before_destroy = true }
}

resource "aws_cloudfront_distribution" "downloads" {
  #checkov:skip=CKV_AWS_68:A WAF costs a fixed monthly fee, and access already needs a signed URL.
  #checkov:skip=CKV2_AWS_47:No WAF is attached, so there is no Log4j rule to add.
  #checkov:skip=CKV_AWS_86:Access logs need a separate target bucket; add one outside this example if required.
  #checkov:skip=CKV_AWS_310:A single bucket is the only origin; there is no second origin to fail over to.
  #checkov:skip=CKV_AWS_374:Installers are for customers anywhere; there is no geographic restriction to apply.
  #checkov:skip=CKV2_AWS_32:The files are downloads, not pages; no security headers are needed.
  #checkov:skip=CKV_AWS_305:There is no page at the root; every URL names a file.
  #checkov:skip=CKV_AWS_174:Before the domain is attached the default CloudFront certificate caps TLS at 1.0; with a domain the minimum is TLSv1.2_2021.
  enabled         = true
  comment         = "Signed-URL downloads from ${var.bucket_name}"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = var.price_class
  aliases         = local.use_domain ? [var.domain_name] : []
  tags            = var.tags

  origin {
    origin_id                = "downloads"
    domain_name              = aws_s3_bucket.downloads.bucket_regional_domain_name
    origin_path              = "/${var.origin_prefix}"
    origin_access_control_id = aws_cloudfront_origin_access_control.downloads.id
  }

  default_cache_behavior {
    target_origin_id       = "downloads"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
    trusted_key_groups     = [aws_cloudfront_key_group.signing.id]
    compress               = false
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_domain ? null : true
    acm_certificate_arn            = local.use_domain ? aws_acm_certificate.downloads[0].arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }

  lifecycle {
    precondition {
      condition     = !var.attach_domain || var.domain_name != null
      error_message = "attach_domain = true needs domain_name: there is no hostname to attach."
    }
  }
}
