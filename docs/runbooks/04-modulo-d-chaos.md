# Runbook 4 -- Módulo D: Chaos Engineering controlado + MTTD

Requiere Módulos A y B ya desplegados y con alertas activas (Runbooks 1-2).
**Corre esto en UNA sola ventana de tiempo por nube** -- son los pasos que
más presupuesto/tiempo de Learner Lab consumen; no los repitas sin
necesidad.

## Experimento 1 -- latencia 200ms en service-b

```bash
# Terminal 1: tráfico de fondo (deja correr durante TODO el experimento)
python3 chaos/load_gen.py --url http://<endpoint>/orders/ord-1002 --duration 180 --out during_h4_<nube>.csv

# Terminal 2: inyecta el fallo (elige el modo/target según dónde estés)
./chaos/h4_latency_service_b.sh tc gke 60 observability-lab        # GKE
./chaos/h4_latency_service_b.sh env ecs 60 observability-lab-cluster service-b   # AWS Fargate

# Anota el FAULT_START impreso, y en paralelo (Terminal 3):
python3 chaos/measure_mttd.py --backend gcp --project-id <id> --alarm-name observability-lab-correlated-degradation --fault-start <FAULT_START>
python3 chaos/measure_mttd.py --backend aws --region us-east-1 --alarm-name observability-lab-correlated-degradation --fault-start <FAULT_START>
```

## Experimento 2 -- error rate 10% en data-service

```bash
python3 chaos/load_gen.py --url http://<endpoint>/orders/ord-1002 --duration 180 --out during_h5_<nube>.csv &
./chaos/h5_error_rate_data_service.sh gke 60 observability-lab
./chaos/h5_error_rate_data_service.sh ecs 60 observability-lab-cluster data-service
python3 chaos/measure_mttd.py --backend <gcp|aws> ...
```

## Preguntas a responder con datos reales (para el reporte)

1. **¿MTTD < 2 minutos?** Compara el `MTTD=...s` impreso por
   `measure_mttd.py` contra 120s, en CADA experimento y CADA nube donde se
   ejecutó.
2. **¿Se degradó el SLO?** Compara `during_h4_<nube>.csv`/`during_h5_<nube>.csv`
   contra una corrida de baseline sin fallo (mismo `load_gen.py`, sin el
   script de chaos corriendo) -- p50/p95/p99 antes/durante, igual que la
   tabla ya usada en `GameDay_Plan.pdf` de la actividad anterior.
3. **¿Se consumió el error budget?** Con SLO de disponibilidad asumido
   (ej. 99.5% mensual -> error budget de 0.5%), calcula qué fracción de
   ese presupuesto mensual consumió la ventana del experimento:
   `(peticiones_fallidas_o_degradadas / peticiones_totales_del_mes_asumido) / 0.005`.
   Documentar el supuesto de tráfico mensual usado para el cálculo
   (no hay tráfico de producción real que medir).
4. **¿La alerta fue accionable?** ¿El mensaje de la alerta (SNS/notification
   channel) traía suficiente contexto (trace_id/enlace a logs) para que
   alguien sin este contexto supiera qué mirar primero? Responder con la
   captura real del mensaje recibido, no en abstracto.

## Evidencia a capturar

- Los 2 (o 4, si se corrió en ambas nubes) CSV de `load_gen.py`.
- La salida completa de `measure_mttd.py` (incluye el MTTD calculado).
- Gráfico de latencia real por request durante cada experimento (reutilizar
  el script de matplotlib ya usado para `GameDay_Plan.pdf` si sigue
  disponible, o generar uno nuevo a partir de los CSV de arriba).
- Captura del mensaje de alerta recibido (email/SNS/notification channel).
