| Métrica | Sin OTel (baseline) | Con OTel SDK | Overhead |
|---|---|---|---|
| Latencia promedio | 1059.92 ms | 1212.87 ms | +14.4% |
| Latencia p95 | 1290.05 ms | 1607.40 ms | +24.6% |
| Latencia p99 | 1399.94 ms | 1918.36 ms | +37.0% |
| Error rate | 0.00 % | 0.00 % | +0.0% |
| Throughput | 43.39 req/s | 38.84 req/s | -10.5% |

Latencia adicional p99: **+518.42 ms** (+37.0%)

### CPU promedio por contenedor

Muestreado con `docker stats --no-stream` cada ~1-2s durante toda la ventana de carga (60 VUs, 5 min), promediado sobre todas las muestras -- no un snapshot puntual.

| Contenedor | Sin OTel (baseline) | Con OTel SDK | Overhead |
|---|---|---|---|
| `service-a` | 56.92% | 60.45% | +3.53 pp (+6.2%) |
| `service-b` | 3.48% | 6.59% | +3.11 pp (+89.5%) |
| `otel-collector` | 0.23% | 1.54% | +1.32 pp (+584.6%) |
