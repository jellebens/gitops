# jaeger — distributed tracing (platform service)

Jaeger **v2** all-in-one (card #162): a single arm64 pod that is an
OpenTelemetry Collector distribution — OTLP receivers, embedded **Badger**
storage with bounded retention, and the Jaeger query UI, all in one binary
configured by one OTel-style YAML file. Stood up because JUPITER is genuinely
microservices now (lar → price/forecast services, reporting, trainer CronJob)
and cross-service timeouts are invisible without traces.

> **Nothing emits traces yet.** This is only the backend. Instrumenting the
> services (OTel SDK in the jupiter services + zeus `prices_jupiter` client,
> with trace-context propagation) is a separate follow-up card.

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
| UI (LAN) | `http://jaeger.lab.local` (shared gateway VIP `192.168.50.200`; HTTPRoute in `gateway-config`, A record + serial bump in `.config/lab/coredns-lab.yaml`) |
| Query API (in-cluster) | `http://jaeger-query.jaeger:16686` (this is what the Grafana datasource uses) |
| Metrics | `:8888/metrics` on `jaeger-collector` (ServiceMonitor, kube-prometheus-stack) |

## Pointing a service at it (OTel SDK, once instrumented)

Standard OTel environment variables — no code-level endpoint config needed:

```yaml
env:
  # gRPC (preferred):
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://jaeger-collector.jaeger.svc.cluster.local:4317"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "grpc"
  # or HTTP: endpoint http://jaeger-collector.jaeger.svc.cluster.local:4318
  #          protocol http/protobuf
  - name: OTEL_SERVICE_NAME
    value: "price-service"
```

If the emitting pod ever gets an egress-lockdown CNP, remember to allow
4317/4318 to the `jaeger` namespace (ingress side is already allowed here for
`zeus`, `jupiter-central`, `jupiter-tervuren` — `networkPolicy.otlpNamespaces`).

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
curl -s http://jaeger.lab.local/api/services | jq    # [] until instrumented
# smoke-test ingest from an allowed namespace (zeus/jupiter-*):
#   grpcurl -plaintext jaeger-collector.jaeger:4317 list
```
