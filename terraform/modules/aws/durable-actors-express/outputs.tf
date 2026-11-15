output "express_bucket" {
  description = "S3 Express directory bucket. Feeds durable-actors storage.bucket."
  value       = aws_s3_directory_bucket.express.bucket
}

output "express_bucket_arn" {
  description = "s3express ARN of the directory bucket (the only resource s3express:CreateSession is granted on)."
  value       = local.express_arn
}

output "express_zone_name" {
  description = "This account's name for the Express zone. Pin the actor node group (durable-actors placement.zone) here."
  value       = data.aws_availability_zone.express.name
}

output "checkpoint_bucket" {
  description = "Regional checkpoint and artifact bucket. Feeds storage.s3.checkpoint.bucket, storage.artifactBucket and the relaycast/relayfile deployer artifactBucket."
  value       = module.checkpoint.bucket_name
}

output "actor_role_arn" {
  description = "Actor storage role. Feeds storage.s3.actorRoleArn (actorCredentials: assume-role)."
  value       = aws_iam_role.actor.arn
}

output "durable_actors_values" {
  description = "durable-actors chart values for this storage."
  value = {
    storage = {
      provider       = "s3"
      bucket         = aws_s3_directory_bucket.express.bucket
      artifactBucket = module.checkpoint.bucket_name
      s3 = {
        region           = data.aws_region.current.region
        actorCredentials = "assume-role"
        actorRoleArn     = aws_iam_role.actor.arn
        checkpoint       = { bucket = module.checkpoint.bucket_name }
      }
    }
    placement = { zone = data.aws_availability_zone.express.name }
  }
}
