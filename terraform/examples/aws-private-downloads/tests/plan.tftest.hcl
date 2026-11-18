# Plans and applies the private downloads bucket and its distribution against mock
# providers, so no cloud credentials are needed. The bucket policy embeds the
# distribution ARN, which is unknown at plan, so the runs apply (to the mock).
# No override_during: OpenTofu does not support it; computed values that are
# asserted on get a mock default.
mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn                         = "arn:aws:s3:::example-private-downloads"
      bucket_regional_domain_name = "example-private-downloads.s3.us-west-2.amazonaws.com"
    }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      arn         = "arn:aws:cloudfront::111111111111:distribution/EXAMPLEDIST"
      domain_name = "d1111111111111.cloudfront.net"
    }
  }
  mock_resource "aws_cloudfront_key_group" {
    defaults = { id = "11111111-2222-4333-8444-111111111111" }
  }
  mock_data "aws_cloudfront_cache_policy" {
    defaults = { id = "22222222-3333-4444-8555-222222222222" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:111111111111:certificate/33333333-4444-4555-8666-777777777777" }
  }
}

variables {
  account_id  = "111111111111"
  region      = "us-west-2"
  bucket_name = "example-private-downloads"
  signing_public_keys = {
    example-signing-1 = "-----BEGIN PUBLIC KEY-----\nTUlJQklqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FROEFNSUlCQ2dLQ0FRRUFleGFtcGxl\n-----END PUBLIC KEY-----\n"
  }
}

run "private_versioned_encrypted" {
  command = apply
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.downloads.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The default encryption is SSE-S3."
  }
  assert {
    condition     = one(aws_s3_bucket_versioning.downloads.versioning_configuration).status == "Enabled"
    error_message = "Versioning is on."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.downloads.block_public_acls,
      aws_s3_bucket_public_access_block.downloads.block_public_policy,
      aws_s3_bucket_public_access_block.downloads.ignore_public_acls,
      aws_s3_bucket_public_access_block.downloads.restrict_public_buckets,
    ])
    error_message = "The bucket is never public."
  }
  assert {
    condition     = one(aws_s3_bucket_ownership_controls.downloads.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs are off."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.downloads.rule).noncurrent_version_expiration[0].noncurrent_days == 180 && one(aws_s3_bucket_lifecycle_configuration.downloads.rule).abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Old versions expire after 180 days and stale multipart uploads after 7."
  }
}

run "bucket_policy_least_privilege" {
  command = apply
  assert {
    condition = anytrue([for s in jsondecode(aws_s3_bucket_policy.downloads.policy).Statement :
    s.Sid == "DenyInsecureTransport" && s.Effect == "Deny" && s.Condition.Bool["aws:SecureTransport"] == "false"])
    error_message = "Plain HTTP is denied."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_s3_bucket_policy.downloads.policy).Statement :
      s.Sid == "AllowCloudFrontRead" && s.Effect == "Allow" && s.Principal.Service == "cloudfront.amazonaws.com" &&
      s.Action == "s3:GetObject" && s.Resource == "arn:aws:s3:::example-private-downloads/desktop/*" &&
    s.Condition.StringEquals["AWS:SourceArn"] == "arn:aws:cloudfront::111111111111:distribution/EXAMPLEDIST"])
    error_message = "CloudFront gets GetObject on the origin prefix, for this distribution only."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.downloads.policy).Statement : s if s.Effect == "Allow"]) == 1
    error_message = "CloudFront's read is the only Allow."
  }
  assert {
    condition     = !strcontains(aws_s3_bucket_policy.downloads.policy, "ListBucket")
    error_message = "No list grant: a missing key answers 403."
  }
}

run "distribution_defaults" {
  command = apply
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.default_cache_behavior).viewer_protocol_policy == "https-only"
    error_message = "Viewers use HTTPS only."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.default_cache_behavior).allowed_methods == toset(["GET", "HEAD"])
    error_message = "GET and HEAD only."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.default_cache_behavior).trusted_key_groups == tolist([aws_cloudfront_key_group.signing.id]) && aws_cloudfront_key_group.signing.name == "example-private-downloads-signers"
    error_message = "Every request needs a signed URL from the key group."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.default_cache_behavior).cache_policy_id == data.aws_cloudfront_cache_policy.caching_disabled.id && data.aws_cloudfront_cache_policy.caching_disabled.name == "Managed-CachingDisabled"
    error_message = "Nothing is cached, so a replaced object is served at once."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.origin).origin_path == "/desktop" && aws_cloudfront_origin_access_control.downloads.signing_behavior == "always"
    error_message = "The origin is the prefix, read with a signed origin access control."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.downloads.aliases) == 0 && length(aws_acm_certificate.downloads) == 0
    error_message = "Without a domain there is no alias and no certificate."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.viewer_certificate).cloudfront_default_certificate
    error_message = "The default CloudFront certificate is used."
  }
  assert {
    condition     = aws_cloudfront_distribution.downloads.price_class == "PriceClass_100" && aws_cloudfront_distribution.downloads.http_version == "http2and3" && aws_cloudfront_distribution.downloads.is_ipv6_enabled
    error_message = "Defaults: cheapest price class, HTTP/2 and 3, IPv6."
  }
}

run "certificate_without_alias" {
  command = apply
  variables {
    domain_name = "downloads.example.com"
  }
  assert {
    condition     = length(aws_acm_certificate.downloads) == 1 && aws_acm_certificate.downloads[0].validation_method == "DNS"
    error_message = "Step one plans a DNS-validated certificate."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.downloads.aliases) == 0 && one(aws_cloudfront_distribution.downloads.viewer_certificate).cloudfront_default_certificate
    error_message = "The domain is not attached yet."
  }
}

run "domain_attached" {
  command = apply
  variables {
    domain_name   = "downloads.example.com"
    attach_domain = true
  }
  assert {
    condition     = aws_cloudfront_distribution.downloads.aliases == toset(["downloads.example.com"])
    error_message = "The alias is the domain."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.downloads.viewer_certificate).minimum_protocol_version == "TLSv1.2_2021" && one(aws_cloudfront_distribution.downloads.viewer_certificate).ssl_support_method == "sni-only"
    error_message = "SNI with TLS 1.2 or later."
  }
}

run "attach_without_domain_fails" {
  command = plan
  variables {
    attach_domain = true
  }
  expect_failures = [aws_cloudfront_distribution.downloads]
}

run "fixed_key_name" {
  command = plan
  assert {
    condition     = aws_cloudfront_public_key.signing["example-signing-1"].name == "example-signing-1"
    error_message = "The key keeps its fixed name, so an import does not plan a replacement."
  }
}

run "two_keys_in_group" {
  command = apply
  variables {
    signing_public_keys = {
      example-signing-1 = "-----BEGIN PUBLIC KEY-----\nTUlJQklqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FROEFNSUlCQ2dLQ0FRRUFleGFtcGxl\n-----END PUBLIC KEY-----\n"
      example-signing-2 = "-----BEGIN PUBLIC KEY-----\nTUlJQklqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FROEFNSUlCQ2dLQ0FRRUFleGFtcGxl\n-----END PUBLIC KEY-----\n"
    }
  }
  assert {
    condition     = length(aws_cloudfront_key_group.signing.items) == 2 && toset(aws_cloudfront_key_group.signing.items) == toset([for k in aws_cloudfront_public_key.signing : k.id])
    error_message = "Both keys are in the key group."
  }
  assert {
    condition     = length(output.signing_public_key_ids) == 2
    error_message = "Both key ids are output."
  }
}

run "bad_public_key_fails" {
  command = plan
  variables {
    signing_public_keys = { example-signing-1 = "not a key" }
  }
  expect_failures = [var.signing_public_keys]
}

run "empty_keys_fail" {
  command = plan
  variables {
    signing_public_keys = {}
  }
  expect_failures = [var.signing_public_keys]
}
