data "aws_caller_identity" "current" {}

# Collector config content is injected via the `env:` confmap provider
# (`--config=env:OTEL_CONFIG`) instead of a mounted file, since Fargate
# awsvpc tasks have no EFS volume wired up in this lab module. Falls back to
# a minimal generic pipeline via try() so `terraform plan` still works even
# before the app repo's otel-collector/collector-config.aws.yaml exists.
locals {
  otel_collector_config = try(
    file("${path.module}/../../../otel-collector/collector-config.aws.yaml"),
    <<-YAML
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch: {}
    exporters:
      logging:
        verbosity: normal
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [logging]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [logging]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [logging]
    YAML
  )
}

# ---------------------------------------------------------------------------
# Networking — minimal VPC with two public subnets, no NAT gateway.
# Fargate tasks get public IPs directly; acceptable for a lab, not for prod.
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "service_a" {
  name                 = "${var.project_name}/service-a"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "service_b" {
  name                 = "${var.project_name}/service-b"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pulls images from ECR and ships logs to CloudWatch.
resource "aws_iam_role" "execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to read the DATABASE_URL secret for injection as
# a task-definition `secrets` entry (only granted when a secret ARN is set).
data "aws_iam_policy_document" "execution_secrets" {
  count = var.database_url_secret_arn != "" ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.database_url_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = var.database_url_secret_arn != "" ? 1 : 0
  name   = "${var.project_name}-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# Task role: least-privilege runtime permissions for the app containers.
# Empty by default; the OTel Collector sidecar exports over OTLP (no AWS API
# calls needed) so no extra policy is attached unless exporters change.
resource "aws_iam_role" "task" {
  name               = "${var.project_name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

# ---------------------------------------------------------------------------
# CloudWatch Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "service_a" {
  name              = "/ecs/${var.project_name}/service-a"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "service_a_collector" {
  name              = "/ecs/${var.project_name}/service-a-otel-collector"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "service_b" {
  name              = "/ecs/${var.project_name}/service-b"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "service_b_collector" {
  name              = "/ecs/${var.project_name}/service-b-otel-collector"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Public HTTP ingress for the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

resource "aws_security_group" "service_a" {
  name        = "${var.project_name}-service-a-sg"
  description = "service-a tasks: 8000 from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "app port from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-service-a-sg" }
}

resource "aws_security_group" "service_b" {
  name        = "${var.project_name}-service-b-sg"
  description = "service-b tasks: 8001 from service-a only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "app port from service-a"
    from_port       = 8001
    to_port         = 8001
    protocol        = "tcp"
    security_groups = [aws_security_group.service_a.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-service-b-sg" }
}

# Collector sidecars listen on 4317/4318 inside their own task's network
# namespace only (localhost, since sidecars in the same Fargate task share a
# network stack) — no additional SG ingress rule is required for that path.
# The rule below allows service-a's task ENI to reach service-b's collector
# port too, in case cross-task OTLP forwarding is ever wired up.
resource "aws_security_group_rule" "service_b_otlp_from_service_a" {
  type                     = "ingress"
  from_port                = 4317
  to_port                  = 4318
  protocol                 = "tcp"
  security_group_id        = aws_security_group.service_b.id
  source_security_group_id = aws_security_group.service_a.id
  description               = "OTLP from service-a task ENI"
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "service_a" {
  name        = "${var.project_name}-svc-a-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_a.arn
  }
}

# ---------------------------------------------------------------------------
# ECS task definitions
#
# The OTel Collector runs as a sidecar container inside each service's task
# definition rather than as its own ECS service behind Cloud Map / Service
# Connect. Tradeoff: simpler for a lab (no service discovery, no extra ALB
# target group, each task's telemetry exports over localhost) at the cost of
# running N collector processes instead of one shared collector — fine at
# this scale, but a shared collector service would be the better choice once
# task count or collector-side processing (tail sampling, etc.) grows.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "service_a" {
  family                   = "${var.project_name}-service-a"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn             = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "service-a"
      image     = "${aws_ecr_repository.service_a.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8000, protocol = "tcp" }
      ]
      environment = concat(
        [
          { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
          { name = "SERVICE_B_URL", value = "http://service-b.${var.project_name}.local:8001" },
        ],
        # DATABASE_URL viaja como env var plana solo si no hay secret ARN
        # (fallback dev/demo); en un despliegue real siempre debe venir de
        # `secrets` (ver bloque de abajo), nunca de las dos formas a la vez.
        var.database_url_secret_arn == "" ? [
          { name = "DATABASE_URL", value = var.database_url }
        ] : []
      )
      secrets = var.database_url_secret_arn != "" ? [
        { name = "DATABASE_URL", valueFrom = var.database_url_secret_arn }
      ] : []
      dependsOn = [
        { containerName = "otel-collector", condition = "START" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service_a.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "service-a"
        }
      }
    },
    {
      name      = "otel-collector"
      image     = var.otel_collector_image
      essential = true
      command   = ["--config=env:OTEL_CONFIG"]
      environment = [
        { name = "OTEL_CONFIG", value = local.otel_collector_config }
      ]
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service_a_collector.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "otel-collector"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "service_b" {
  family                   = "${var.project_name}-service-b"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn             = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "service-b"
      image     = "${aws_ecr_repository.service_b.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8001, protocol = "tcp" }
      ]
      environment = concat(
        [{ name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" }],
        var.database_url_secret_arn == "" ? [
          { name = "DATABASE_URL", value = var.database_url }
        ] : []
      )
      secrets = var.database_url_secret_arn != "" ? [
        { name = "DATABASE_URL", valueFrom = var.database_url_secret_arn }
      ] : []
      dependsOn = [
        { containerName = "otel-collector", condition = "START" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service_b.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "service-b"
        }
      }
    },
    {
      name      = "otel-collector"
      image     = var.otel_collector_image
      essential = true
      command   = ["--config=env:OTEL_CONFIG"]
      environment = [
        { name = "OTEL_CONFIG", value = local.otel_collector_config }
      ]
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service_b_collector.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "otel-collector"
        }
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# Service discovery (Cloud Map) so service-a can resolve service-b by name.
# ---------------------------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name = "${var.project_name}.local"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "service_b" {
  name = "service-b"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ---------------------------------------------------------------------------
# ECS services
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "service_a" {
  name            = "service-a"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service_a.arn
  desired_count   = var.service_a_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.service_a.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service_a.arn
    container_name    = "service-a"
    container_port    = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "service_b" {
  name            = "service-b"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service_b.arn
  desired_count   = var.service_b_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.service_b.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service_b.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
