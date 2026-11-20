output "bucket" {
  description = "The downloads bucket."
  value       = aws_s3_bucket.downloads.bucket
}

output "distribution_id" {
  description = "The CloudFront distribution id."
  value       = aws_cloudfront_distribution.downloads.id
}

output "distribution_arn" {
  description = "The CloudFront distribution ARN (the bucket policy's AWS:SourceArn)."
  value       = aws_cloudfront_distribution.downloads.arn
}

output "distribution_domain_name" {
  description = "The CloudFront domain name. Point the CNAME for domain_name here."
  value       = aws_cloudfront_distribution.downloads.domain_name
}

output "signing_public_key_ids" {
  description = "Key name => CloudFront public key id. The id is the Key-Pair-Id of a signed URL."
  value       = { for n, k in aws_cloudfront_public_key.signing : n => k.id }
}

output "key_group_id" {
  description = "The key group id (the default behaviour's trusted key group)."
  value       = aws_cloudfront_key_group.signing.id
}

output "certificate_arn" {
  description = "The us-east-1 certificate ARN, or null without domain_name."
  value       = one(aws_acm_certificate.downloads[*].arn)
}

output "certificate_validation_records" {
  description = "DNS records to add at the DNS host to validate the certificate (empty without domain_name)."
  value = local.certificate ? [for o in aws_acm_certificate.downloads[0].domain_validation_options : {
    name  = o.resource_record_name
    type  = o.resource_record_type
    value = o.resource_record_value
  }] : []
}
