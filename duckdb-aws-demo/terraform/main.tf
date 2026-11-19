data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  azs        = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  suffix     = random_id.suffix.hex

  images_ready = var.duckdb_image_tag != "" && var.proxy_image_tag != ""

  # DuckDB connects through the S3 Tables Iceberg REST endpoint under this alias.
  catalog_alias = "lake"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "duckdb-s3tables-demo"
  }
}
