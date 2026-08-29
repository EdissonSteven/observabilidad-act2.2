# ---------------------------------------------------------------------------
# RDS PostgreSQL -- base de datos real de `data-service` (Módulo A del
# laboratorio integrador: "acceda a ... AWS RDS").
#
# Decisión de alcance: `orders`/`inventory` (service-a/service-b) SIGUEN en
# el Postgres-on-Fargate ya existente (main.tf) -- no se toca ese camino ya
# probado de la Actividad 2.2. Esta RDS es la base de datos PROPIA de
# `data-service` (tabla `customers`, ver scripts/init-customers-db.sql),
# separada a propósito: aísla el blast radius de un fallo de RDS al tercer
# microservicio nuevo, y evita migrar infraestructura que ya funciona solo
# para cumplir el requisito de la nueva actividad. Ver
# docs/madurez-observabilidad.md (dominio 8) para la discusión de por qué
# unificar todo en RDS sería el siguiente paso de madurez, no el primero.
#
# Tamaño elegido por costo, no por rendimiento: db.t3.micro es la instancia
# RDS más pequeña de uso general, con Single-AZ (sin standby) y sin backups
# automáticos (backup_retention_period = 0) -- explícitamente NO apto para
# producción, sí apto para una ventana de Game Day de un par de horas en un
# Learner Lab de $19. Ver docs/runbooks/ para el procedimiento de
# apply -> capturar evidencia -> destroy en la misma sesión.
# ---------------------------------------------------------------------------

resource "aws_security_group" "rds_customers" {
  count       = var.deploy_rds ? 1 : 0
  name        = "${var.project_name}-rds-customers-sg"
  description = "RDS PostgreSQL (customers, data-service): 5432 solo desde data-service"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres desde data-service"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.data_service[0].id]
  }

  dynamic "ingress" {
    for_each = var.db_admin_cidr != "" ? [var.db_admin_cidr] : []
    content {
      description = "Postgres desde tu IP (seed manual de scripts/init-customers-db.sql)"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-customers-sg" }
}

# RDS requiere un subnet group con subredes en >= 2 AZ. Reutiliza las
# mismas subredes públicas del resto del módulo (sin NAT gateway en este
# lab) pero `publicly_accessible = false` mantiene la instancia sin IP
# pública propia -- solo accesible dentro de la VPC, vía el SG de arriba.
resource "aws_db_subnet_group" "customers" {
  count      = var.deploy_rds ? 1 : 0
  name       = "${var.project_name}-customers-subnets"
  subnet_ids = aws_subnet.public[*].id

  tags = { Name = "${var.project_name}-customers-subnets" }
}

resource "random_password" "rds_customers" {
  count            = var.deploy_rds ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "customers" {
  count      = var.deploy_rds ? 1 : 0
  identifier = "${var.project_name}-customers"

  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage     = 20 # mínimo soportado por RDS Postgres -- ~free-tier sized
  storage_type           = "gp2"
  db_name                = "customersdb"
  username               = "app"
  password               = random_password.rds_customers[0].result
  db_subnet_group_name   = aws_db_subnet_group.customers[0].name
  vpc_security_group_ids = [aws_security_group.rds_customers[0].id]

  multi_az                = false
  publicly_accessible     = false
  backup_retention_period = 0 # sin backups automáticos -- instancia desechable de laboratorio
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = { Name = "${var.project_name}-customers", Purpose = "game-day-lab-disposable" }
}

# DSN completo, guardado en Secrets Manager (nunca como env var plana en la
# task definition) -- mismo patrón de `secrets` ya usado por
# database_url_secret_arn para service-a/service-b.
resource "aws_secretsmanager_secret" "customers_database_url" {
  count                   = var.deploy_rds ? 1 : 0
  name                    = "${var.project_name}/customers-database-url"
  recovery_window_in_days = 0 # borrado inmediato al hacer destroy -- evita costos residuales del secreto
}

resource "aws_secretsmanager_secret_version" "customers_database_url" {
  count     = var.deploy_rds ? 1 : 0
  secret_id = aws_secretsmanager_secret.customers_database_url[0].id
  secret_string = format(
    "postgresql://%s:%s@%s:5432/%s",
    aws_db_instance.customers[0].username,
    random_password.rds_customers[0].result,
    aws_db_instance.customers[0].address,
    aws_db_instance.customers[0].db_name,
  )
}
