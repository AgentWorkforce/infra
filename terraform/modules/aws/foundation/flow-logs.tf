resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${local.name}/flow"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
  depends_on        = [terraform_data.guard]
}
resource "aws_iam_role" "flow" {
  name                 = "${local.name}-flow"
  path                 = local.role_path
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:ec2:${var.region}:${var.account_id}:vpc-flow-log/*" } }
  }] })
  tags       = local.tags
  depends_on = [terraform_data.guard]
}
resource "aws_iam_role_policy" "flow" {
  name = "${local.name}-flow"
  role = aws_iam_role.flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.flow.arn}:*" },
      { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } }
    ]
  })
}
resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow.arn
  log_destination = aws_cloudwatch_log_group.flow.arn
  tags            = local.tags
  depends_on      = [aws_iam_role_policy.flow]
}
