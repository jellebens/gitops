# jupiter-central — central jupiter services landing zone

Landing zone for the **central** (one-per-fleet) jupiter services, per
`zeus:.docs/jupiter/architecture.md` and the P1–P5 card breakdown. First
tenant (card #106): **price-service**. forecast-service and fleet-reporting
land here with later P2/P3 cards.

**Central-only:** nothing in this namespace touches zeus behavior. Zeus keeps
fetching ENTSO-E directly until card #107 flips `prices.source: jupiter` —
and even then it keeps its direct-fetch + local-cache fallback chain.

## price-service

HTTP API over ENTSO-E day-ahead prices, one instance for every bidding zone
and site (source: [jupiter repo](https://github.com/jellebens/jupiter),
`services/price`; image `jellebens/jupiter-price`, arm64, tag = jupiter
release, tracked in [values.yaml](values.yaml)).

- `GET /healthz` — service/version/site document; used by the k8s probes.
- `GET /v1/curve?zone=10YBE----------2&start=<iso>&slots=144&slot_minutes=15`
  — raw zone prices (EUR/kWh) with the zeus-parity staleness guard, last-good
  cache (`primary | cache-fresh | cache | *-partial` labels), ETag/304.
  Per-site markup/export price and slot alignment are cell concerns, applied
  by the consumer.

**In-cluster URL (what zeus/cells configure):**

    http://price-service.jupiter-central.svc.cluster.local:8080

The bidding zone is a **per-request query parameter** — there is no
server-side zone list, hence no ConfigMap in this chart. Consumers bring
their zone (BE = `10YBE----------2`, in zeus values today).

### Config knobs (all env, set by the chart)

| Env var | Source | Meaning |
|---|---|---|
| `PORT` | `service.port` (8080) | listen port |
| `PRICE_CACHE_DIR` | `persistence.mountPath` (`/data`) | per-zone last-good curve cache, on the PVC |
| `SITE_ID` | `siteId` (`central`) | D4 site identity for a central singleton |
| `ENTSOE_API_TOKEN` | `jupiter-central-secrets` (SealedSecret) | ENTSO-E Transparency API token |

The token secret is mounted `envFrom ... optional: true` and the service
tolerates its absence (serves persisted last-good curves; a fetch without a
token degrades exactly like an ENTSO-E outage), so the app comes up before
the secret is sealed.

### Sealing the ENTSO-E token

Sealed blobs are **namespace-scoped**: the zeus `ENTSOE_TOKEN` blob in
`.config/lab/zeus.yaml` cannot be reused here (and the key name differs —
this service reads `ENTSOE_API_TOKEN`). Seal the same plaintext token for
this namespace and paste it into `.config/lab/jupiter-central.yaml`:

```sh
echo -n "$ENTSOE_TOKEN" | kubeseal --raw \
  --namespace jupiter-central --name jupiter-central-secrets \
  --controller-name sealed-secrets --controller-namespace argocd
```

### Storage

`price-service-cache` PVC, `local-path` (k3s default, node-pinned RWO — the
deployment uses `strategy: Recreate` accordingly). The cache is tiny and
re-fetchable from ENTSO-E, so NAS durability (zeus's `smb` class) is not
warranted: losing the node only costs one fresh fetch per zone.

### Monitoring & alerting

- **No `/metrics` yet** (0.1.0 is a stdlib-only serving layer), so the
  ServiceMonitor template exists but is **disabled by default** — enabling it
  now would only pin `up` at 0. The jupiter card that adds prometheus_client
  flips `serviceMonitor.enabled` and adds real price-source metrics.
- **PriceFeedDegraded-equivalent gap:** without metrics there is no central
  view of `primary/cache/-partial` serving. Zeus's own
  `ZeusPriceSourceDegraded`/`ZeusPricePartialCoverage`/`ZeusNoPriceData`
  rules remain the price-feed-degraded signal for the live battery.
- Until then the PrometheusRule alerts on **availability** via
  kube-state-metrics: `JupiterPriceServiceDown` (no ready replica for 10m)
  and `JupiterPriceServiceCrashLooping` (restart churn).

### Network policy

Ingress-only CiliumNetworkPolicy (repo convention — egress stays fully open;
the service needs the public ENTSO-E API): inbound allowed from the
`observability` namespace (future scrape) and from
`networkPolicy.allowedClientNamespaces` (`zeus`) to port 8080 only.

## Argo CD

Application `jupiter-central`
([applications/templates/jupiter-central/](../../applications/templates/jupiter-central/)),
project `landing-zones`, sync-wave **20** — after the platform layer
(sealed-secrets, cilium, mqtt at 16) and before the zeus landing zone (30),
so the price API exists before any consumer that might be flipped onto it.
