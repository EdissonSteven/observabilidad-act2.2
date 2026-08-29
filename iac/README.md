# Infrastructure as Code

> **Nota (laboratorio integrador, Módulos A-E):** este directorio se
> extendió más allá de lo descrito abajo -- ahora también provisiona el
> tercer microservicio `data-service`, Cloud SQL/RDS, service mesh
> (Istio/App Mesh), alertas de AIOps, VPC Flow Logs y un dashboard de
> seguridad (ver `cloudsql.tf`, `data_service.tf`/`data_service_ecs.tf`,
> `monitoring_aiops.tf`/`cloudwatch_aiops.tf`, `network_security.tf`/
> `vpc_flow_logs.tf`, `security_dashboard.tf`, `appmesh.tf` en cada
> módulo). El paso a paso real para desplegar y validar esas piezas está
> en `docs/runbooks/00-validacion-local-y-preflight.md` en adelante, no en
> los README de este directorio (que documentan la versión base de
> Actividad 2.2). **Decisión de alcance:** el despliegue real de esa
> entrega es solo en GCP -- el módulo AWS queda escrito y validado
> sintácticamente, no desplegado (ver `docs/reporte-ejecutivo-final.md`).

This directory holds the IaC for deploying the observability lab's two
FastAPI services (`service-a`, `service-b`) and the OTel Collector to real
cloud infrastructure, as the dual-cloud complement to the docker-compose
stack used for local development, testing, and evidence-gathering.

```
iac/
  terraform/gcp/    Provisions a GKE cluster (VPC, node pool, Artifact
                     Registry, IAM) AND deploys the workloads onto it via
                     the kubernetes Terraform provider — cluster to running
                     pods in a single `terraform apply`.
  terraform/aws/    Provisions ECS Fargate infrastructure (VPC, ECR, ECS
                     cluster, ALB, IAM, CloudWatch) and the ECS services
                     that run the containers — a parallel, independent path
                     to a working deployment on AWS instead of GCP.
  helm/otel-collector/  A Kubernetes-native alternative for deploying just
                     the Collector onto an already-provisioned cluster
                     (e.g. the GKE cluster from terraform/gcp), decoupled
                     from the cluster's own Terraform state so its config
                     can be iterated on independently with `helm upgrade`.
```

## Terraform vs. Helm — why both

- **Terraform** owns cloud *infrastructure provisioning*: networks, the
  managed Kubernetes/ECS control plane, IAM, registries, load balancers —
  the resources that cost money and that only a cloud API can create.
- **Helm** owns *workload deployment* onto infrastructure that already
  exists. The GKE Terraform module deploys workloads too (via the
  `kubernetes` provider), so the Helm chart isn't strictly required to get
  a running system — it's included to show the alternative, more common
  pattern of "Terraform for infra, Helm for what runs on it," and to let
  the collector's pipeline config change without touching cluster-level
  Terraform state.

## Why this IaC is not applied in the graded submission

Standing up a real GKE cluster or ECS Fargate + ALB service costs money for
every hour it runs and requires cloud credentials that shouldn't be
embedded in a student repo. The evidence for this lab (traces, metrics,
logs flowing through the pipeline) is gathered by running the stack locally
with `docker-compose` — see the repo root for that setup.

This `iac/` directory is deliberately **written to apply cleanly, not
executed**: real Terraform (`terraform plan`/`apply` would succeed given
credentials and a project/account) and a real Helm chart, submitted as
evidence of IaC competency per the rubric, without incurring cloud cost or
requiring reviewers to have cloud access to grade the assignment. Each
module's own README (`terraform/gcp/README.md`, `terraform/aws/README.md`,
`helm/otel-collector/README.md`) has the exact commands to actually run it
against a real account.

## Keeping IaC in sync with the app

Both Terraform modules assume:
- `service-a` listens on `8000`, `service-b` on `8001`, both exposing
  `GET /health`.
- The OTel Collector accepts OTLP on `4317` (gRPC) / `4318` (HTTP).
- Images are named `service-a` / `service-b` and read `SERVICE_B_URL` /
  `OTEL_EXPORTER_OTLP_ENDPOINT` from the environment to reach each other
  and the collector.
- Both Terraform modules read the collector pipeline straight from the app
  repo via `file()`: the GKE module from
  `otel-collector/collector-config.gcp.yaml` (mounted into the pod as a
  ConfigMap), the AWS module from
  `otel-collector/collector-config.aws.yaml` (injected into the Fargate
  sidecar as an `OTEL_CONFIG` env var consumed via `--config=env:OTEL_CONFIG`,
  since Fargate tasks have no volume to mount a file into). If those
  filenames or ports change in the app/Collector configs, update the
  corresponding `iac/terraform/*/main.tf` references.
