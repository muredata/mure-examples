# ECS on AWS Fargate (Graviton, linux/arm64).
#
# UI task: two containers sharing the task's network namespace
#   duckdb - DuckDB 2.0 with the UI server on localhost:4213 (loopback only)
#   proxy  - HAProxy on :8080, the only port the ALB can reach
#
# Loader task: same DuckDB image, runs app.load_tpcds once (uv run duckdemo load-tpcds).

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Fargate tasks: proxy port from the ALB; HTTPS egress"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-tasks" }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Proxy sidecar from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

# HTTPS out: VPC endpoints, the S3 gateway endpoint and ui.duckdb.org through the NAT
# gateway. DNS Firewall decides which names resolve at all.
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to AWS endpoints and the DuckDB UI frontend"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = toset(["duckdb-ui", "proxy", "tpcds-loader"])
  name              = "/${local.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

locals {
  duckdb_image = "${aws_ecr_repository.app["duckdb"].repository_url}:${local.images_ready ? var.duckdb_image_tag : "not-pushed-yet"}"
  proxy_image  = "${aws_ecr_repository.app["proxy"].repository_url}:${local.images_ready ? var.proxy_image_tag : "not-pushed-yet"}"
  public_url   = "https://${aws_cloudfront_distribution.ui.domain_name}"

  duckdb_env_common = [
    { name = "AWS_REGION", value = var.region },
    { name = "TABLE_BUCKET_ARN", value = aws_s3tables_table_bucket.tpcds.arn },
    { name = "S3TABLES_NAMESPACE", value = var.tpcds_namespace },
    { name = "CATALOG_ALIAS", value = local.catalog_alias },
    { name = "DATA_DIR", value = "/data" },
  ]

  duckdb_healthcheck = {
    command     = ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:4213/info', timeout=4).status == 200 else 1)"]
    interval    = 15
    timeout     = 5
    retries     = 3
    startPeriod = 90
  }

  hardening = {
    readonlyRootFilesystem = true
    privileged             = false
    # ECS adds these defaults; writing them avoids a perpetual diff.
    systemControls = []
    volumesFrom    = []
    linuxParameters = {
      initProcessEnabled = true
      capabilities       = { add = [], drop = ["ALL"] }
    }
  }

  # Spill limits leave room on the ephemeral volume for the DuckDB database files.
  ui_spill_gb     = floor(var.ui_ephemeral_storage_gib * 0.8)
  loader_spill_gb = floor(var.loader_ephemeral_storage_gib * 0.4)
}

# --- UI ----------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "ui" {
  family                   = "${local.name}-duckdb-ui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ui_cpu
  memory                   = var.ui_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.ui.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  ephemeral_storage {
    size_in_gib = var.ui_ephemeral_storage_gib
  }

  # Bind mount on the task's ephemeral storage. The image declares VOLUME /data owned by
  # the non-root user (uid 10001); Fargate copies that directory and keeps its ownership.
  volume {
    name = "data"
  }

  container_definitions = jsonencode([
    merge(local.hardening, {
      name         = "duckdb"
      image        = local.duckdb_image
      essential    = true
      user         = "10001:10001"
      stopTimeout  = 30
      portMappings = []
      environment = concat(local.duckdb_env_common, [
        { name = "DUCKDB_MEMORY_LIMIT", value = var.ui_duckdb_memory_limit },
        { name = "DUCKDB_THREADS", value = tostring(floor(var.ui_cpu / 1024)) },
        { name = "DUCKDB_MAX_TEMP_SIZE", value = "${local.ui_spill_gb}GB" },
      ])
      mountPoints = [{ sourceVolume = "data", containerPath = "/data", readOnly = false }]
      healthCheck = local.duckdb_healthcheck
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs["duckdb-ui"].name
          awslogs-region        = var.region
          awslogs-stream-prefix = "duckdb"
        }
      }
    }),
    merge(local.hardening, {
      name         = "proxy"
      image        = local.proxy_image
      essential    = true
      stopTimeout  = 10
      environment  = [{ name = "PUBLIC_ORIGIN", value = local.public_url }]
      portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
      mountPoints  = []
      dependsOn    = [{ containerName = "duckdb", condition = "HEALTHY" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs["proxy"].name
          awslogs-region        = var.region
          awslogs-stream-prefix = "proxy"
        }
      }
    }),
  ])
}

resource "aws_ecs_service" "ui" {
  name                   = "${local.name}-duckdb-ui"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.ui.arn
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  desired_count          = local.images_ready ? var.ui_desired_count : 0
  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  # One task at a time: the UI keeps notebooks on the task's local storage.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 120

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "proxy"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.ui, aws_vpc_endpoint.interface, aws_vpc_endpoint.s3]
}

# --- TPC-DS loader -----------------------------------------------------------------------

resource "aws_ecs_task_definition" "loader" {
  family                   = "${local.name}-tpcds-loader"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.loader_cpu
  memory                   = var.loader_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.loader.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  ephemeral_storage {
    size_in_gib = var.loader_ephemeral_storage_gib
  }

  volume {
    name = "data"
  }

  container_definitions = jsonencode([
    merge(local.hardening, {
      name      = "loader"
      image     = local.duckdb_image
      essential = true
      user      = "10001:10001"
      command   = ["python", "-m", "app.load_tpcds", "--scale-factor", "10"]
      environment = concat(local.duckdb_env_common, [
        { name = "DUCKDB_MEMORY_LIMIT", value = var.loader_duckdb_memory_limit },
        { name = "DUCKDB_THREADS", value = tostring(floor(var.loader_cpu / 1024)) },
        { name = "DUCKDB_MAX_TEMP_SIZE", value = "${local.loader_spill_gb}GB" },
      ])
      mountPoints = [{ sourceVolume = "data", containerPath = "/data", readOnly = false }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs["tpcds-loader"].name
          awslogs-region        = var.region
          awslogs-stream-prefix = "loader"
        }
      }
    }),
  ])
}
