/**
 * Fase 4 -- Análisis de overhead OTel.
 *
 * Carga: 60 VUs constantes durante 5 minutos contra GET /orders/{id}
 * (el endpoint que atraviesa ambos servicios + PostgreSQL x2).
 *
 * Uso (ver benchmark/run-benchmark.sh para el flujo completo baseline vs OTel):
 *   k6 run --env MODE=otel     --env BASE_URL=http://service-a:8000 k6-load-test.js
 *   k6 run --env MODE=baseline --env BASE_URL=http://service-a:8000 k6-load-test.js
 */
import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";
const MODE = __ENV.MODE || "otel";
const ORDER_IDS = ["ord-1001", "ord-1002", "ord-1003", "ord-1004", "ord-1005"];

export const options = {
  scenarios: {
    warmup: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [{ duration: "20s", target: 20 }],
      gracefulRampDown: "5s",
      tags: { scenario: "warmup" },
    },
    sustained_load: {
      executor: "constant-vus",
      vus: 60,
      duration: "5m",
      startTime: "20s",
      gracefulStop: "10s",
      tags: { scenario: "sustained" },
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"],
    http_req_failed: ["rate<0.02"],
  },
  summaryTrendStats: ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"],
};

export default function () {
  const orderId = ORDER_IDS[Math.floor(Math.random() * ORDER_IDS.length)];
  const res = http.get(`${BASE_URL}/orders/${orderId}`, { tags: { mode: MODE } });

  check(res, {
    "status 200": (r) => r.status === 200,
    "body tiene order": (r) => {
      try {
        return JSON.parse(r.body).order !== undefined;
      } catch {
        return false;
      }
    },
  });

  sleep(Math.random() * 0.3 + 0.1); // 100-400ms entre requests por VU
}

export function handleSummary(data) {
  const m = data.metrics;
  const result = {
    mode: MODE,
    timestamp: new Date().toISOString(),
    metrics: {
      latency_avg_ms: m.http_req_duration.values.avg,
      latency_p95_ms: m.http_req_duration.values["p(95)"],
      latency_p99_ms: m.http_req_duration.values["p(99)"],
      error_rate_pct: (m.http_req_failed?.values.rate || 0) * 100,
      throughput_rps: m.http_reqs.values.rate,
      total_requests: m.http_reqs.values.count,
    },
  };
  return {
    stdout: JSON.stringify(result, null, 2),
    [`/results/results_${MODE}.json`]: JSON.stringify(result, null, 2),
  };
}
