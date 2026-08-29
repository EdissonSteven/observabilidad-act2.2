# Runbook 0 -- Validación local (gratis) + preflight de nube

Ejecuta esto ANTES de gastar un solo dólar/crédito de AWS o GCP. Todo en
este runbook corre en tu máquina, sin nube real.

## Paso 0 -- Ya validado de forma estática (sin Docker ni credenciales de nube)

El entorno donde se escribió este código no tiene daemon de Docker
corriendo ni credenciales de AWS/GCP, así que lo siguiente ya se verificó
de forma estática antes de entregarte el código, y NO hace falta que lo
repitas salvo que edites algo:

| Verificación | Herramienta | Alcance real | Resultado |
|---|---|---|---|
| Gramática HCL de los 18 archivos `.tf` (`iac/terraform/{aws,gcp}/*.tf`) | `python-hcl2` | Solo sintaxis/gramática -- **no** valida el esquema del provider (nombres de argumentos, tipos, recursos que no existen) ni lógica semántica | 18/18 OK |
| Sintaxis de los 15 archivos Python (`services/*/app/*.py`, `chaos/*.py`, `scripts/generate-report-docx.py`) | `python3 -m py_compile` | Solo sintaxis -- no ejecuta el código ni prueba imports/lógica | 15/15 OK |
| Sintaxis de los 4 scripts de shell (`chaos/*.sh`, `scripts/*preflight_check.sh`) | `bash -n` | Solo sintaxis | 4/4 OK |
| `docker-compose.yaml` completo (con `data-service` agregado) | `docker compose config` | Valida YAML + interpolación de variables + referencias entre servicios; **no** construye ni corre los contenedores | Válido |
| 9 archivos YAML de observabilidad (Prometheus, Grafana, Loki, Tempo, Collector x3) | `yaml.safe_load` | Solo que el YAML parsea | 9/9 OK |

**Lo que esto NO reemplaza** (y por eso siguen los Pasos 1-6 de este
runbook): `terraform validate`/`plan` reales contra el esquema del
provider (pueden existir errores de tipo/argumento que `python-hcl2` no
detecta), correr los contenedores de verdad y ver el trace de 3 saltos en
Jaeger, y los preflights de permisos reales contra tu Learner Lab/proyecto
GCP -- nada de eso se puede simular sin credenciales ni Docker daemon.

## Paso 1 -- Validar el stack local completo con el 3er microservicio

```bash
git pull   # o clona el repo si es la primera vez
docker compose up -d --build
docker compose ps    # todo "healthy"/"running" en ~30-60s, incluyendo data-service
```

Genera tráfico y confirma el trace de 3 saltos:

```bash
curl http://localhost:8000/orders/ord-1002 | jq
# La respuesta debe traer "order", "inventory" Y "customer" -- si "customer"
# viene con "error": algo falla entre service-a y data-service, revisa
# docker compose logs data-service antes de seguir.
```

En Jaeger (http://localhost:16686 -> Service: service-a -> Find Traces):
confirma un único trace con spans de los 3 servicios, y que
`order.fetch_customer` -> `customer.fetch_from_db` trae los atributos
`db.system.name`, `db.namespace`, `db.operation.name`,
`db.collection.name` (Módulo A, semántica de DB).

## Paso 2 -- Validar la regla de correlación de AIOps localmente

```bash
open http://localhost:9091/alerts   # o curl http://localhost:9091/api/v1/rules
```

Confirma que `CorrelatedDegradation` y `NaiveStatic5xx` aparecen cargadas
(estado "inactive" es normal en reposo). Esto valida la fórmula ANTES de
traducirla a CloudWatch/Cloud Monitoring (donde un error de sintaxis sí
puede costar tiempo/dinero de debug).

## Paso 3 -- Ensayar los 2 experimentos de caos localmente

```bash
# Terminal 1: deja corriendo tráfico de fondo
python3 chaos/load_gen.py --url http://localhost:8000/orders/ord-1002 --duration 120 --out /tmp/baseline_local.csv

# Terminal 2, mientras el anterior corre: experimento 1 (latencia)
./chaos/h4_latency_service_b.sh tc local 40

# Terminal 3, en paralelo al experimento: mide MTTD
python3 chaos/measure_mttd.py --backend local --fault-start <FAULT_START impreso arriba>
```

Repite con `./chaos/h5_error_rate_data_service.sh local 40` para el
experimento 2. Si `CorrelatedDegradation` nunca pasa a "firing" en ninguno
de los dos, ajusta los umbrales en
`observability/prometheus/alert_rules.yml` (el `> 0.3` de latencia y las
ventanas de 30m del baseline) ANTES de replicar la lógica en la nube --
es mucho más barato iterar aquí.

## Paso 4 -- Preflight de AWS (Learner Lab)

```bash
aws configure   # pega las credenciales temporales del panel de AWS Academy
./scripts/aws_preflight_check.sh us-east-1
```

Lee cada `[WARN]`/`[FAIL]` -- en particular si `enable_app_mesh=true` es
viable (política AppMesh en LabRole) y si Security Hub/DevOps Guru están
disponibles (probablemente no, ya está previsto en el IaC).

## Paso 5 -- Preflight de GCP

```bash
gcloud auth login
gcloud config set project <tu-project-id>
./scripts/gcp_preflight_check.sh <tu-project-id>
```

Confirma sobre todo: facturación habilitada (los \$300 de crédito
vinculados) y si hay una organización (Security Command Center).

## Paso 6 -- `terraform plan` en seco, sin aplicar nada todavía

```bash
cd iac/terraform/aws
terraform init
terraform plan -var deploy_rds=false -var enable_app_mesh=false -out=/tmp/aws.tfplan
# Revisa el resumen: ¿cuántos recursos, de qué tipo? ¿algo inesperado?

cd ../gcp
terraform init
terraform plan -var project_id=<tu-project-id> -out=/tmp/gcp.tfplan
```

Si algo en el plan te sorprende o un error de sintaxis aparece, compártelo
en la conversación antes de aplicar -- reviso el `.tf` correspondiente
contigo. Solo después de un `plan` limpio en ambos lados se sigue al
runbook del Módulo A (`01-modulo-a-arquitectura.md`).
