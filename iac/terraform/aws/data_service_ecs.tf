# ---------------------------------------------------------------------------
# data-service -- tercer microservicio ECS Fargate (Módulo A), mismo patrón
# sidecar-Collector que service-a/service-b en main.tf. Ver rds.tf para la
# base de datos (RDS) que consume, y variables.tf `deploy_rds`/`FAULT_INJECT_ERROR_RATE`
# (Módulo D, experimento 2) para el interruptor de caos.
# ---------------------------------------------------------------------------

resource "aws_security_group" "data_service" {
  name        = "${var.project_name}-data-service-sg"
  description = "data-service tasks: 8002 desde service-a únicamente"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "app port desde service-a"
    from_port       = 8002
    to_port         = 8002
    protocol        = "tcp"
    security_groups = [aws_security_group.service_a.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-data-service-sg" }
}

resource "aws_cloudwatch_log_group" "data_service" {
  name              = "/ecs/${var.project_name}/data-service"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "data_service_collector" {
  name              = "/ecs/${var.project_name}/data-service-otel-collector"
  retention_in_days = var.log_retention_days
}

resource "aws_service_discovery_service" "data_service" {
  name = "data-service"

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

resource "aws_ecs_task_definition" "data_service" {
  family                   = "${var.project_name}-data-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn

  dynamic "proxy_configuration" {
    for_each = var.enable_app_mesh ? [1] : []
    content {
      type           = "APPMESH"
      container_name = "envoy"
      properties = {
        AppPorts         = "8002"
        EgressIgnoredIPs = "169.254.170.2,169.254.169.254"
        IgnoredUID       = "1337"
        ProxyEgressPort  = "15001"
        ProxyIngressPort = "15000"
      }
    }
  }

  container_definitions = jsonencode(concat([
    {
      name      = "data-service"
      image     = "${aws_ecr_repository.data_service.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8002, protocol = "tcp" }
      ]
      environment = concat(
        [
          { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
          { name = "CLOUD_PROVIDER", value = "aws" },
          { name = "ENVIRONMENT", value = "aws-academy" },
          # Módulo D, experimento 2: 0 en reposo. El runbook de caos lo
          # sube a 0.10 (ver chaos/h5_error_rate_data_service.sh) forzando
          # un nuevo deployment de ESTA task definition con el valor
          # cambiado -- ECS Fargate no permite editar env vars de una task
          # corriendo sin redeploy, así que la ventana del experimento
          # incluye ese redeploy (~1-2 min) en el tiempo total medido.
          { name = "FAULT_INJECT_ERROR_RATE", value = var.fault_inject_error_rate }
        ],
        # DATABASE_URL viaja como secreto de Secrets Manager cuando
        # deploy_rds = true (rds.tf); si deploy_rds = false, cae al DSN
        # plano de var.database_url (mismo Postgres-on-Fargate que
        # service-a/service-b, solo para validar el resto del stack sin
        # pagar RDS todavía).
        var.deploy_rds ? [] : [
          { name = "DATABASE_URL", value = var.database_url }
        ]
      )
      secrets = var.deploy_rds ? [
        { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret_version.customers_database_url[0].arn }
      ] : []
      dependsOn = [
        { containerName = "otel-collector", condition = "START" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.data_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "data-service"
        }
      }
    },
    {
      name      = "otel-collector"
      image     = var.otel_collector_image
      essential = true
      command   = ["--config=env:OTEL_CONFIG"]
      environment = [
        { name = "OTEL_CONFIG", value = local.otel_collector_config },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ENVIRONMENT", value = "aws-academy" },
        { name = "TEMPO_ENDPOINT", value = var.tempo_endpoint }
      ]
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.data_service_collector.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "otel-collector"
        }
      }
    }
  ], var.enable_app_mesh ? [local.envoy_container["data-service"]] : []))
}

resource "aws_ecs_service" "data_service" {
  name            = "data-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.data_service.arn
  desired_count   = var.data_service_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.data_service.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.data_service.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_ecs_service.postgres]
}

resource "aws_ecr_repository" "data_service" {
  name                 = "${var.project_name}/data-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
