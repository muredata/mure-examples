# Least-privilege roles for the Fargate tasks.
#  - execution role: pull images from ECR, write logs (used by ECS, not by DuckDB)
#  - ui role:     read every table in the bucket; create/change tables only in the sandbox namespace
#  - loader role: create and write tables in the demo bucket (not reachable from the UI)

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:*"]
    }
  }
}

# --- Execution role ----------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for g in aws_cloudwatch_log_group.ecs : "${g.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-and-log"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# --- Shared S3 Tables read access ----------------------------------------------------------

locals {
  bucket_arn = aws_s3tables_table_bucket.tpcds.arn
  tables_arn = "${aws_s3tables_table_bucket.tpcds.arn}/table/*"

  s3tables_read_actions = [
    "s3tables:GetTableBucket",
    "s3tables:ListNamespaces",
    "s3tables:GetNamespace",
    "s3tables:ListTables",
    "s3tables:GetTable",
    "s3tables:GetTableMetadataLocation",
    "s3tables:GetTableData",
  ]
  s3tables_write_actions = [
    "s3tables:CreateTable",
    "s3tables:PutTableData",
    "s3tables:UpdateTableMetadataLocation",
    "s3tables:DeleteTable",
    "s3tables:RenameTable",
  ]
}

# --- UI task role --------------------------------------------------------------------------

resource "aws_iam_role" "ui" {
  name               = "${local.name}-duckdb-ui"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "ui" {
  statement {
    sid       = "ReadAllTables"
    actions   = local.s3tables_read_actions
    resources = [local.bucket_arn, local.tables_arn]
  }

  statement {
    sid       = "WriteSandboxOnly"
    actions   = local.s3tables_write_actions
    resources = [local.bucket_arn, local.tables_arn]
    condition {
      test     = "StringEquals"
      variable = "s3tables:namespace"
      values   = [var.sandbox_namespace]
    }
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      sid = "EcsExec"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "ui" {
  name   = "s3tables-read-all-write-sandbox"
  role   = aws_iam_role.ui.id
  policy = data.aws_iam_policy_document.ui.json
}

# --- Loader task role ----------------------------------------------------------------------

resource "aws_iam_role" "loader" {
  name               = "${local.name}-tpcds-loader"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# The loader is never user-facing: it may write any table in the demo bucket.
data "aws_iam_policy_document" "loader" {
  statement {
    sid       = "ReadWriteDemoBucket"
    actions   = concat(local.s3tables_read_actions, local.s3tables_write_actions, ["s3tables:CreateNamespace"])
    resources = [local.bucket_arn, local.tables_arn]
  }
}

resource "aws_iam_role_policy" "loader" {
  name   = "s3tables-write-demo-bucket"
  role   = aws_iam_role.loader.id
  policy = data.aws_iam_policy_document.loader.json
}
