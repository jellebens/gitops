# jaeger — distributed tracing (platform service)

Jaeger **v2** all-in-one (card #162): a single arm64 pod that is an
OpenTelemetry Collector distribution — OTLP receivers, embedded **Badger**
storage with bounded retention, and the Jaeger query UI, all in one binary
configured by one OTel-style YAML file. Stood up because JUPITER is genuinely
microservices now (lar → price/forecast services, reporting, trainer CronJob)
and cross-service timeouts are invisible without traces.

> **Emitters wired (card #179).** The jupiter services (price / forecast /
> lar / reporting) and zeus's `prices_jupiter` client emit OTLP spans with W3C
> trace-context propagation, env-gated per landing zone (`tracing.enabled`,
> default ON for jupiter-central / jupiter-tervuren / zeus). Traces flow once
> the #179 jupiter + zeus releases are deployed. The end-to-end runbook
> ("see a lar → price-service trace") is jupiter `docs/OPERATIONS.md` §8.

## How it's deployed

| | |
|---|---|
| Argo CD app | `jaeger` (project `platform-services`, sync-wave `19`) |
| Namespace | `jaeger` |
| App definition | [`applications/templates/jaeger/jaeger-app.yaml`](../../applications/templates/jaeger/jaeger-app.yaml) |
| Env values | `.config/<env>/jaeger.yaml` |
| Image | `jaegertracing/jaeger:2.19.0` — official multi-arch, **linux/arm64 verified** in the registry manifest list |

## Endpoints

| What | Address |
|---|---|
| OTLP gRPC ingest | `jaeger-collector.jaeger.svc.cluster.local:4317` |
| OTLP HTTP ingest | `jaeger-collector.jaeger.svc.cluster.local:4318` |
| UI (LAN) | **`https://jaeger.lab.local`** (lab-CA cert `jaeger-server-tls`, per-hostname `jaeger-https` listener on the shared gateway — influxdb/hermes pattern; `http://` also answers on the shared listener). The lab CA must be trusted on the client for a clean padlock. (Gateway VIP `192.168.50.200`; HTTPRoute + listener in `gateway-config`, A record in `.config/lab/coredns-lab.yaml`) |
| Query API (in-cluster) | `http://jaeger-query.jaeger:16686` (this is what the Grafana datasource uses) |
| Metrics | `:8888/metrics` on `jaeger-collector` (ServiceMonitor, kube-prometheus-stack) |

## Pointing a service at it (the real #179 wiring)

The jupiter/zeus emitters read exactly ONE env var — the endpoint. Its
**presence is the switch**: unset means the tracing helper
(`jupiter_shared.tracing` / `zeus.tracing`) constructs zero SDK objects.
Service name / version / `site_id` are set in code (resource attributes), not
via `OTEL_SERVICE_NAME`. The landing zones render it values-gated:

```yaml
# landingzones/{jupiter-central,jupiter-tervuren,zeus}/values.yaml (#179)
tracing:
  enabled: true   # default ON for these three zones
  endpoint: "http://jaeger-collector.jaeger.svc.cluster.local:4317"  # gRPC
```

which becomes, on each Deployment (price/forecast/reporting, the lar, zeus):

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://jaeger-collector.jaeger.svc.cluster.local:4317"
```

The exporters speak OTLP/**gRPC** (4317); the HTTP receiver (4318) stays
available for anything else. If the emitting pod ever gets an egress-lockdown
CNP, remember to allow 4317 to the `jaeger` namespace — the jupiter-tervuren
and reporting opt-in egress lists already pre-declare it (ingress side is
already allowed here for `zeus`, `jupiter-central`, `jupiter-tervuren` —
`networkPolicy.otlpNamespaces`).

## Storage, retention & sizing

- **Badger** (embedded key-value store) on a **`local-path` PVC (5Gi)** —
  node-local POSIX storage like InfluxDB/EMQX, not the SMB share. No
  Elasticsearch/Cassandra: overkill for a homelab.
- **Retention = Badger span TTL = `168h` (7d)** (`jaeger.retention` in
  `.config/<env>/jaeger.yaml`); expired spans drop out during compaction, so
  disk stays bounded. 5Gi is generous for homelab trace volume — bump both
  knobs together if longer look-back is ever needed.
- **Single replica, `strategy: Recreate`, by design**: Badger is single-writer
  (directory lock) and the PVC is RWO. Tracing is a diagnostic aid, not on any
  control path — a pod restart loses only in-flight spans. There is no HA
  story short of switching backends (see Tempo below).

## Security / network policy

Scoped, **ingress-only** CNP (egress fully open — repo convention):
OTLP 4317/4318 only from the workload namespaces listed in
`networkPolicy.otlpNamespaces`; UI 16686 from the gateway (`ingress` entity)
and in-cluster clients; 8888/13133 from observability + `cluster` (kubelet
probes). The UI and query API are **unauthenticated** — acceptable because
they are reachable only on the LAN via the gateway or in-cluster.

## Grafana

`Jaeger` datasource (uid `jaeger`), **statically mounted** via
`grafana.extraConfigmapMounts` (ConfigMap `grafana-jaeger-datasource` in
`platform/observability-config`) — the datasource sidecar loses a boot race
and its reload 403s, so static mount is the house pattern. Traces are explored
in Grafana Explore or at `http://jaeger.lab.local` directly.

## The Tempo alternative (evaluated, not chosen)

Grafana **Tempo** monolithic would offer the same OTLP ingest with a
Grafana-native UI (TraceQL), object/local storage and multi-tenancy. Chosen
against (owner default was Jaeger; trade-off is not stark): Tempo has **no UI
of its own** (Grafana-only — losing Grafana loses trace browsing), TraceQL is
another query language to learn, its search is less immediate for the classic
"find slow request by service/operation" flow, and its extra machinery
(compactor/metrics-generator) buys nothing at this scale. Jaeger v2 gives a
purpose-built trace UI at `jaeger.lab.local` + the same Grafana Explore
integration via the datasource. Revisit Tempo if trace volume outgrows Badger
or TraceQL/metrics-generation becomes desirable — ingest is OTLP either way,
so instrumented services would not change.

## Verify

```sh
kubectl -n jaeger rollout status deploy/jaeger
kubectl -n jaeger get pvc jaeger-badger              # Bound (local-path)
dig @192.168.50.180 jaeger.lab.local +short          # -> 192.168.50.200
curl -s http://jaeger.lab.local/api/services | jq    # jupiter-lar/jupiter-price/jupiter-forecast/jupiter-reporting/zeus (#183 names; pre-#183 spans show as lar/price-service/... until the 7d retention ages them out)
# smoke-test ingest from an allowed namespace (zeus/jupiter-*):
#   grpcurl -plaintext jaeger-collector.jaeger:4317 list
```
