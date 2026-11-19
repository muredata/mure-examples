# VPC endpoints: all AWS API traffic from the tasks stays on the AWS network.
#  - S3 (gateway): Iceberg data and metadata files in the table bucket, ECR image layers
#  - S3 Tables (interface): catalog operations through the Iceberg REST endpoint
#  - ECR api/dkr, CloudWatch Logs, STS: image pulls, task logs, credentials
#  - SSM messages: only used when enable_execute_command = true

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpc-endpoints"
  description = "Interface VPC endpoints: HTTPS from the Fargate tasks only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_tasks" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from Fargate tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = { Name = "${local.name}-s3" }
}

locals {
  interface_endpoints = toset(concat(
    ["s3tables", "ecr.api", "ecr.dkr", "logs", "sts"],
    var.enable_execute_command ? ["ssmmessages"] : [],
  ))
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoints
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.key}" }
}

# The S3 Tables endpoint only serves this account's table bucket.
data "aws_iam_policy_document" "s3tables_endpoint" {
  statement {
    sid       = "OnlyTheDemoTableBucket"
    actions   = ["s3tables:*"]
    resources = [aws_s3tables_table_bucket.tpcds.arn, "${aws_s3tables_table_bucket.tpcds.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_vpc_endpoint_policy" "s3tables" {
  vpc_endpoint_id = aws_vpc_endpoint.interface["s3tables"].id
  policy          = data.aws_iam_policy_document.s3tables_endpoint.json
}
