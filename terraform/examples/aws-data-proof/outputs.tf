output "proof_contract" {
  description = "Non-secret source/lease/module/transport identities. Capture before guest termination."
  value = {
    account_id         = var.account_id, region = var.region, source_sha = var.source_sha, run_id = var.run_id, vpc_id = var.vpc_id,
    lease              = var.pippen, phase = local.phase, marker = local.marker,
    database           = { identifier = module.postgres.instance_identifier, arn = module.postgres.resource_arn, host = module.postgres.host, secret_arn = module.postgres.master_user_secret_arn, subnet_group = module.postgres.db_subnet_group_name, parameter_group = "${local.name}-pg", retained_automated_backups = true, skip_final_snapshot = true },
    snapshot           = try(aws_db_snapshot.marker[0].db_snapshot_identifier, null),
    restored           = try({ identifier = aws_db_instance.restored[0].identifier, host = aws_db_instance.restored[0].address, resource_id = aws_db_instance.restored[0].resource_id }, null),
    bucket             = module.objects.bucket_name, payload_key = local.payload, payload_sha256 = var.payload_sha256, payload_version_id = var.payload_version_id, receipt_key = local.receipt, prefix = local.prefix, ca_sha256 = var.rds_ca_sha256,
    sentinel           = { key = aws_s3_object.sentinel.key, version_id = aws_s3_object.sentinel.version_id, etag = aws_s3_object.sentinel.etag },
    compute            = try({ instance_id = aws_instance.verifier[0].id, root_volume_ids = [for disk in aws_instance.verifier[0].root_block_device : disk.volume_id], eni_id = aws_instance.verifier[0].primary_network_interface_id }, null),
    verifier_identity  = { launch_template_id = aws_launch_template.verifier.id, role_arn = aws_iam_role.verifier.arn, profile_arn = aws_iam_instance_profile.verifier.arn },
    security_group_ids = [aws_security_group.database.id, aws_security_group.verifier.id]
    private_subnet_ids = local.private_ids
    owned_network = var.create_private_subnets == null ? null : {
      subnet_ids            = local.private_ids
      subnets               = var.create_private_subnets
      route_table_id        = aws_route_table.private[0].id
      route_association_ids = [aws_route_table_association.private_first[0].id, aws_route_table_association.private_second[0].id]
    }
  }
}
