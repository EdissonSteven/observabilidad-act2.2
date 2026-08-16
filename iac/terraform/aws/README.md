# ECS Fargate deployment (Terraform)

Provisions a minimal VPC (2 public subnets across 2 AZs, IGW, no NAT
gateway), ECR repos for `service-a`/`service-b`, an ECS Fargate cluster with
Container Insights, an ALB routing to `service-a`, and ECS services running
each app container alongside an OTel Collector **sidecar** in the same task
definition (see the comment in `main.tf` above the task definitions for the
sidecar-vs-shared-collector tradeoff). The collector's pipeline config is
read from `otel-collector/collector-config.aws.yaml` in the repo root and
injected into each sidecar as an `OTEL_CONFIG` environment variable
(`--config=env:OTEL_CONFIG`) since Fargate `awsvpc` tasks have no volume to
mount a config file into.

This module is **not applied** as part of the graded submission (see
`iac/README.md` for why) — it is provided as reproducible, ready-to-run IaC.
It also provisions Postgres itself: no RDS instance here, `postgres:16-alpine`
runs as a third ECS Fargate service (`aws_ecs_service.postgres`), reachable
by `service-a`/`service-b` via Cloud Map DNS (`postgres.<project_name>.local`).
Simpler and cheaper for evaluating this module than standing up RDS; for a
real deployment, swap it for an `aws_db_instance` and point
`database_url`/`database_url_secret_arn` at it instead.

## Prerequisites

1. An AWS account and the `aws` CLI configured with credentials that can
   create VPC/ECS/ECR/IAM/ALB resources:
   ```bash
   aws configure
   aws sts get-caller-identity   # confirms account ID / credentials
   ```
2. Terraform >= 1.5.
3. Both services read a single `DATABASE_URL` DSN (`postgresql://user:pass@host:5432/appdb`,
   same as `services/*/app/db.py` locally). The default `database_url`
   already points at this module's own Postgres service
   (`postgres.observability-lab.local`) — no extra setup needed for a lab
   run. For a real deployment against RDS instead, create the full DSN as a
   secret and pass its ARN via `database_url_secret_arn` — nothing is
   hardcoded here:
   ```bash
   aws secretsmanager create-secret --name observability-lab/database-url \
     --secret-string 'postgresql://app:<password>@<rds-endpoint>:5432/appdb'
   ```
   Without a secret ARN, the module falls back to the plain-text
   `database_url` variable (dev/demo only, never for a real deployment).

## Usage

```bash
cd iac/terraform/aws
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Defaults in `variables.tf` are lab-sized (single ALB, 2 AZs, 512 CPU /
1024 MiB per task shared between the app container and its collector
sidecar). Override with `-var` or a `terraform.tfvars` file.

## Building and pushing images to ECR

Run this once the ECR repositories exist (first `terraform apply`, or
scope it with `-target=aws_ecr_repository.service_a
-target=aws_ecr_repository.service_b` to create just the repos first):

```bash
ACCOUNT_ID=$(terraform output -raw account_id)
REGION=us-east-1

aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

docker build -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/observability-lab/service-a:latest \
  ../../../services/service-a
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/observability-lab/service-a:latest

docker build -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/observability-lab/service-b:latest \
  ../../../services/service-b
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/observability-lab/service-b:latest
```

Then run (or re-run) `terraform apply` so the ECS services pick up the
pushed images (or force a new deployment: `aws ecs update-service
--cluster <cluster> --service service-a --force-new-deployment`).

## Seeding Postgres

The Fargate Postgres task has no volume to auto-run `scripts/init-db.sql` on
startup (unlike the local `docker-compose`, which mounts it into
`/docker-entrypoint-initdb.d/`), so run it once by hand after the first
`apply`. Set `db_admin_cidr = "<your-ip>/32"` (get it from
`curl -s https://checkip.amazonaws.com`) via `-var` or `terraform.tfvars`
so the Postgres security group accepts your IP, then:

```bash
TASK_ARN=$(aws ecs list-tasks --cluster $(terraform output -raw ecs_cluster_name) --service-name postgres --query 'taskArns[0]' --output text)
ENI_ID=$(aws ecs describe-tasks --cluster $(terraform output -raw ecs_cluster_name) --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
PG_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text)

docker run --rm -e PGPASSWORD=secret -v "$(pwd)/../../../scripts:/scripts:ro" \
  postgres:16-alpine psql -h $PG_IP -U app -d appdb -f /scripts/init-db.sql
```

## Verifying

```bash
curl http://$(terraform output -raw alb_dns_name)/health
curl http://$(terraform output -raw alb_dns_name)/orders/ord-1001
```

Note: this module does not deploy Jaeger/Tempo/Grafana, so the Collector's
trace exporter (`var.tempo_endpoint`, default `tempo.invalid:4317`) has
nowhere real to send spans — export attempts will fail and show up as
errors in the collector's CloudWatch Logs. That's expected; it doesn't
block the app→app→DB flow or the Collector's own health. Point
`tempo_endpoint` at a real backend if you deploy one.

## Cost and teardown warning

Fargate tasks, the ALB, NAT-free public IPs, and CloudWatch Logs all incur
ongoing AWS cost — this is **not a free-tier setup** once desired counts
and task sizing scale up. When you're done evaluating:

```bash
terraform destroy
```

Confirm in the AWS Console (ECS, EC2 > Load Balancers, ECR) that no
resources were left behind, especially if any `terraform apply` was
interrupted mid-run.
