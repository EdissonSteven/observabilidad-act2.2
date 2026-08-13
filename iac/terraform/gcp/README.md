# GKE deployment (Terraform)

Provisions a regional GKE cluster in a dedicated VPC, an Artifact Registry
repository, least-privilege IAM for the node pool, and the Kubernetes
workloads (`service-a`, `service-b`, `otel-collector`) via the `kubernetes`
Terraform provider pointed at the cluster it just created.

This module is **not applied** as part of the graded submission (see
`iac/README.md` for why) — it is provided as reproducible, ready-to-run IaC.

## Prerequisites

1. A GCP project with billing enabled.
2. `gcloud` CLI authenticated with an account that has `Owner` or
   `Editor` + `Project IAM Admin` on that project:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project <PROJECT_ID>
   ```
3. Enable the required APIs:
   ```bash
   gcloud services enable \
     container.googleapis.com \
     artifactregistry.googleapis.com \
     compute.googleapis.com \
     iam.googleapis.com
   ```
4. Terraform >= 1.5.

## Usage

```bash
cd iac/terraform/gcp
terraform init
terraform plan -var="project_id=<PROJECT_ID>" -out=tfplan
terraform apply tfplan
```

All other variables (region, cluster size, machine type, etc.) have lab-
appropriate defaults in `variables.tf` — override with `-var` or a
`terraform.tfvars` file as needed.

## Pushing images before (or after) the first apply

The `kubernetes_deployment` resources reference
`${artifact_registry_url}/service-a:${var.image_tag}` and
`.../service-b:${var.image_tag}`. Build and push those images once the
Artifact Registry repository exists (first `terraform apply`, which can be
scoped to just the registry with
`terraform apply -target=google_artifact_registry_repository.images` if you
want to push images before creating the cluster):

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev

docker build -t us-central1-docker.pkg.dev/<PROJECT_ID>/observability-lab/service-a:latest \
  ../../../services/service-a
docker push us-central1-docker.pkg.dev/<PROJECT_ID>/observability-lab/service-a:latest

docker build -t us-central1-docker.pkg.dev/<PROJECT_ID>/observability-lab/service-b:latest \
  ../../../services/service-b
docker push us-central1-docker.pkg.dev/<PROJECT_ID>/observability-lab/service-b:latest
```

Then run (or re-run) `terraform apply` so the Deployments roll out with
the pushed images.

## Fetching kubeconfig

```bash
gcloud container clusters get-credentials $(terraform output -raw cluster_name) \
  --region us-central1 --project <PROJECT_ID>
```

## Cost and teardown warning

GKE Autopilot/Standard clusters, their nodes, and any `LoadBalancer`
Services (`expose_services_externally = true`) incur ongoing GCP cost —
this is **not a free-tier setup**. When you're done evaluating:

```bash
terraform destroy
```

Double-check in the GCP Console that the cluster, VPC, and any load
balancers were actually removed, since orphaned `LoadBalancer` Services
can leave forwarding rules behind even after `terraform destroy` if they
were created outside Terraform's state.
