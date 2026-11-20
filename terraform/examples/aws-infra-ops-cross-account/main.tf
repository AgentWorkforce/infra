# A role in this account for the infra operator (the layered-infra-ops agent),
# assumable only by its named admin role in the operator's home account. The
# home account needs no change: AdministratorAccess there already allows
# sts:AssumeRole, and nothing about that role is touched here.
#
# IAM stores a role principal by its unique id. If the trusted role is ever
# deleted and recreated, this trust silently stops matching (the principal then
# shows as an AROA... id in the console) until this root is applied again.
locals {
  trust_statement = merge(
    {
      Sid       = "OperatorAssumes"
      Effect    = "Allow"
      Principal = { AWS = var.trusted_role_arns }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    },
    var.external_id == null ? {} : { Condition = { StringEquals = { "sts:ExternalId" = var.external_id } } },
  )
}

resource "aws_iam_role" "operator" {
  name                 = var.role_name
  path                 = var.role_path
  description          = "Cross-account access for the infra operator; assumable only by ${join(", ", var.trusted_role_arns)}."
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.trust_statement]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "operator" {
  #checkov:skip=CKV_AWS_274:The operator role is an admin role by design, the same grant as its home-account role; the trust names exact role ARNs, never an account root or a wildcard.
  for_each   = toset(var.policy_arns)
  role       = aws_iam_role.operator.name
  policy_arn = each.value
}
