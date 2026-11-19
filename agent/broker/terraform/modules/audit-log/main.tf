# The credential broker's audit log in CloudWatch Logs, in the broker's
# account. The broker role may only create streams in it and append to them
# (modules/broker-role, audit_log_group_arn). The sessions the broker vends
# there may not touch it at all (modules/elevated-role, DenyBrokerAuditLog).
# Lines arrive hash-chained (broker/src/audit.ts, ship.ts), so a gap or an
# edit shows up when the copy is checked.

resource "aws_cloudwatch_log_group" "audit" {
  name              = var.name
  retention_in_days = var.retention_in_days
  tags              = merge(var.tags, { "managed-by" = "aws-cred-broker" })
}
