# S3 table bucket with the TPC-DS data. Encryption: SSE-S3 (the S3 Tables default).
# Maintenance (compaction, snapshot expiry, unreferenced file removal) is managed by S3 Tables.

locals {
  table_bucket_name = "${local.name}-tpcds-${local.suffix}"
}

resource "aws_s3tables_table_bucket" "tpcds" {
  name          = local.table_bucket_name
  force_destroy = var.force_destroy

  encryption_configuration = {
    sse_algorithm = "AES256"
    kms_key_arn   = null
  }

  maintenance_configuration = {
    iceberg_unreferenced_file_removal = {
      status = "enabled"
      settings = {
        unreferenced_days = 3
        non_current_days  = 7
      }
    }
  }
}

resource "aws_s3tables_namespace" "tpcds" {
  namespace        = var.tpcds_namespace
  table_bucket_arn = aws_s3tables_table_bucket.tpcds.arn
}

resource "aws_s3tables_namespace" "sandbox" {
  namespace        = var.sandbox_namespace
  table_bucket_arn = aws_s3tables_table_bucket.tpcds.arn
}
