output "slots" {
  description = "Slot id to infrastructure mapping for operators, keyed by slot id. Internal: never expose it to customers or customer-facing systems."
  value = {
    for id, slot in local.slots : id => {
      instance_id        = aws_instance.slot[id].id
      data_volume_id     = aws_ebs_volume.data[id].id
      role_arn           = aws_iam_role.slot[id].arn
      secret_name        = slot.secret_name
      secret_arn_pattern = slot.secret_arn_pattern
    }
  }
}

output "security_group_id" {
  description = "Security group shared by the slot hosts."
  value       = aws_security_group.slots.id
}
