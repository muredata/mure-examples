output "ui_url" {
  description = "DuckDB UI (Cognito sign-in required, allow-listed IPs only)."
  value       = local.public_url
}

output "admin_username" {
  value = var.admin_email
}

output "region" {
  value = var.region
}

output "table_bucket_arn" {
  value = aws_s3tables_table_bucket.tpcds.arn
}

output "tpcds_namespace" {
  value = var.tpcds_namespace
}

output "cognito_domain" {
  value = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ui_service" {
  value = aws_ecs_service.ui.name
}

output "loader_task_definition" {
  value = aws_ecs_task_definition.loader.arn
}

output "loader_log_group" {
  value = aws_cloudwatch_log_group.ecs["tpcds-loader"].name
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "task_security_group_id" {
  value = aws_security_group.tasks.id
}

output "images_ready" {
  value = local.images_ready
}
