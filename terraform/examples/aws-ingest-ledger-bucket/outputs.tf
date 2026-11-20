output "bucket" {
  description = "ingestEdge.ledgerBucket.bucket."
  value       = aws_s3_bucket.ledger.bucket
}

output "region" {
  description = "ingestEdge.ledgerBucket.region."
  value       = var.region
}

output "bucket_arn" {
  description = "The ledger bucket's ARN."
  value       = aws_s3_bucket.ledger.arn
}
