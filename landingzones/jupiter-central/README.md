# jupiter-central — central jupiter services landing zone

Landing zone for the **central** (one-per-fleet) jupiter services, per
`zeus:.docs/jupiter/architecture.md` and the P1–P5 card breakdown. Tenants:
**price-service** (card #106), **forecast-service** + its training
CronJob (card #126), and **reporting-service** — the central fleet-reporting /
savings service (jupiter reporting card #161, deployed by gitops card #161-F).

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

- **ServiceMonitor enabled** (card #115): scrapes `GET /metrics` on the API
  port (`http`, 8080). The jupiter card #115 PR wired prometheus_client into
  the price-service with a zeus-parity source taxonomy
  (`jupiter_price_curve_serves_total{zone,source_label}` with
  `primary|primary-partial|cache-fresh|cache|cache-partial|none`, plus
  fetch outcomes/retries, `jupiter_price_cooldown_active`,
  `jupiter_price_cache_age_seconds{zone}`, curve points and build info).
  **Sequencing:** against a pre-`/metrics` image (0.1.0) the scrape 404s and
  `up` reads 0 (noisy `JupiterPriceServiceDown`, otherwise harmless) — the
  flip belongs with/after the first jupiter release that ships `/metrics`.
- **PriceFeedDegraded class** (mirroring zeus's rules; inert until the
  scrape succeeds): `JupiterPriceFeedDegraded` (retry cooldown active or
  cache age > 26h, sustained 30m), `JupiterPricePartialCoverage`
  (`*-partial` serves sustained 6h — the routine end-of-horizon tail
  self-heals at day-ahead publication), `JupiterPriceNoUsableCurve`
  (503 `no_usable_curve` answers for 15m, **critical**). Zeus's own
  `ZeusPriceSourceDegraded`/`ZeusPricePartialCoverage`/`ZeusNoPriceData`
  rules remain the price-feed signal for the live battery.
- **Day-ahead publish-time rules** (card #172; inert until the jupiter
  release carrying PR #52's metrics deploys): tomorrow's day-ahead prices
  only exist from **15:00 Europe/Brussels** (owner rule). The service
  exports `jupiter_price_tomorrow_expected` (0/1, clock+config driven,
  process-global, flips at publish-by, DST-aware) and
  `jupiter_price_tomorrow_present{zone}` (tomorrow's market-local-date
  slots present in the served curve). `JupiterPriceTomorrowMissing`
  (warning) fires on `expected==1 and present==0` sustained 45m
  (≈ 15:45 local); `JupiterPriceTomorrowMissingCritical` escalates the same
  predicate at 2h (≈ 17:00 — the overnight charge plan is then being built
  on a LOCF-flat price tail). The same card gated
  `JupiterPricePartialCoverage` on `expected==1` (with an `absent()`
  fallback that keeps its original behavior until the metrics ship):
  a 36h-horizon serve is `*-partial` all morning *by design*, so the
  ungated 6h sustain would have paged daily at ~06:00. The absolute,
  clock-independent staleness rules (`JupiterPriceFeedDegraded`,
  `JupiterPriceNoUsableCurve`) are deliberately **not** expectation-gated.
  The expected/present state is visible on the zeus `price-grid` dashboard
  (stat + arrival-rhythm timeline, plus a 15:00 time-region marker on the
  realized-price curve).
- Availability: `JupiterPriceServiceDown` (`up==0` for 10m via the
  ServiceMonitor), `JupiterPriceServiceNoReplica` (kube-state-metrics view,
  catches a deleted deployment too) and `JupiterPriceServiceCrashLooping`
  (restart churn).

### Network policy

Ingress-only CiliumNetworkPolicy (repo convention — egress stays fully open;
the service needs the public ENTSO-E API): inbound allowed from the
`observability` namespace (future scrape) and from
`networkPolicy.allowedClientNamespaces` (`zeus`) to port 8080 only.

## forecast-service (card #126)

Central forecast serving API + training CronJob (source:
[jupiter repo](https://github.com/jellebens/jupiter), `services/forecast`;
image `jellebens/jupiter-forecast`, arm64, one image for both — the CronJob
overrides the entrypoint with the `jupiter-forecast-train` console script).

**The server stays dumb** (jupiter #120 design): the trainer bakes a
ready-to-serve 168 h hourly kWh horizon per `(site_id, target)` onto the
shared artifact PVC; serving is a pure local slice — no model evaluation, no
Open-Meteo fetch, no InfluxDB read on the request path.

- `GET /healthz` — readiness; answers before/without any artifact (a missing
  artifact 503s `/v1/forecast` with `no_usable_forecast`, never `/healthz`).
- `GET /v1/forecast/{site_id}?target=critical_load|whole_home&start=<iso>&hours=38`
  — baked hourly kWh + the 168-slot hour-of-week p90 peak profile.
- `GET /metrics` — same port.

**In-cluster URL (what zeus/cells configure at the P3 cutover):**

    http://forecast-service.jupiter-central.svc.cluster.local:8080

### Config knobs (env, set by the chart)

| Env var | Workload | Source | Meaning |
|---|---|---|---|
| `PORT` | server | `forecast.service.port` (8080) | listen port |
| `SITE_ID` | server | `siteId` (`central`) | D4 site identity |
| `FORECAST_ARTIFACT_DIR` | both | `forecast.persistence.mountPath` (`/artifacts`) | artifact PVC (server ro, trainer rw) |
| `INFLUX_URL` / `INFLUX_ORG` / `INFLUX_BUCKET` | trainer | `forecast.trainer.influx.*` | the fleet's shared bucket (same wiring zeus uses) |
| `INFLUX_TOKEN` | trainer | `jupiter-influx` (SealedSecret) | InfluxDB read token |
| `--sites-json /etc/jupiter/sites.json` | trainer | `forecast.sites` via the `forecast-train-sites` ConfigMap | per-site coordinates/params (trainer rejects unknown keys) |

### Training CronJob

`forecast-train`, every 6 h (`17 */6 * * *`), `concurrencyPolicy: Forbid`.
Per run it reads site-tagged history from InfluxDB, fetches Open-Meteo
temps, fits the zeus-parity forecaster ladder and atomically writes
`<site_id>/<target>.json`. A failed target writes NOTHING (the server keeps
the previous artifact; its age gauge is the alert signal) and the job exits
non-zero. `include_untagged: true` for tervuren is TRANSITION-ERA ONLY (zeus
started tagging 2026-07-04) — drop it after the P4 backfill.

**⚠ OWNER STEP — the CronJob ships `suspend: true`** because the InfluxDB
token cannot ship with the chart (sealed blobs are namespace-scoped; the
zeus blob cannot be reused, and this trainer reads `INFLUX_TOKEN`, not
zeus's `INFLUXDB_TOKEN`). Everything else deploys and runs. To activate
training, in ONE commit to `.config/lab/jupiter-central.yaml`:

```sh
echo -n "$INFLUX_TOKEN" | kubeseal --raw \
  --namespace jupiter-central --name jupiter-influx \
  --controller-name sealed-secrets --controller-namespace argocd
```

1. paste the output as `forecast.secret.sealedSecret.encryptedData.INFLUX_TOKEN`,
2. flip `forecast.trainer.suspend` to `false`.

### Storage & scheduling

`forecast-artifacts` PVC, 1Gi `local-path`, RWO — artifacts are fully
regenerated every trainer run, so NAS durability is not warranted (same
rationale as the price cache). Both the deployment (read-only) and the
CronJob (writable) mount it: `local-path` is node-pinned, but its
`WaitForFirstConsumer` binding gives the PV node affinity that the scheduler
honors for every pod, so server and trainer co-locate on the volume's node
automatically (deployment uses `strategy: Recreate` accordingly). Node down
= pods Pending until it returns; acceptable for v1, `smb` RWX is the later
escape hatch.

### Monitoring & alerting

- **ServiceMonitor** on `/metrics` (port 8080; the 0.3.0 image ships it from
  day one — no price-style 404 window).
- `JupiterForecastServiceDown` — `up==0` 10m (warning; consumers fall back
  to their last fetch or local baseline forecaster).
- `JupiterForecastArtifactStale` — `jupiter_forecast_artifact_age_seconds`
  > 24h sustained 1h (warning): four consecutive missed/failed 6-hourly
  trainings, or the CronJob left suspended. Gauge updates at serve time, so
  it only moves while consumers poll.
- `JupiterForecastTrainingFailing` — kube-state-metrics: a failed
  `forecast-train` Job with no successful run in the last 6h (the `unless`
  clause keeps an old failed Job in history from alerting past a later
  success). Silent while suspended-and-never-run.

### Network policy

`forecast-service` gets the same ingress-only CiliumNetworkPolicy as the
price-service (same consumer values: `observability` + `zeus`, port 8080
only). The trainer pods are deliberately NOT selected by any policy — they
need egress to InfluxDB (`influxdb` namespace) and the public
`api.open-meteo.com`, both covered by the namespace's open egress
(ingress-only convention; an egress lockdown stays a human-reviewed step).

## reporting-service (card #161-F)

The central fleet-reporting / savings service (jupiter repo `services/reporting`,
image `jellebens/jupiter-reporting:0.7.0`, package `jupiter_reporting`,
ADR-0013). **OWNER NAMING DECISION:** the k8s Deployment/Service is
`reporting-service` (NO `jupiter-` prefix — it is already in the
`jupiter-central` namespace, matching `price-service` / `forecast-service`); only
the Docker image keeps the registry-convention `jupiter-reporting` name.

A **pure consumer**, never on any actuation path — a broker or InfluxDB outage
degrades it and never crashes it (`/healthz` + `/metrics` keep serving). It:

- subscribes to the lars' retained MQTT `jupiter/<site>/plan` + `.../heartbeat`
  and re-exposes them as `jupiter_reporting_*` Prometheus gauges (honoring the
  retained-doc staleness rule);
- reads the site-tagged realized `zeus_state` / `zeus_savings` series from the
  shared InfluxDB `zeus` bucket to emit `jupiter_savings_*`;
- writes durable `jupiter_state` / `jupiter_daily_savings` back to that bucket
  (byte-parity line builder → jupiter and zeus points overwrite, not duplicate).

Central singleton (`site_id=central`), single replica (Recreate). **No PVC and
no CronJob** (unlike forecast) — all state is in InfluxDB / Prometheus; the
realized refresh runs on an in-process timer.

### Config knobs (all env, set by the chart via the `reporting-service-config`
ConfigMap + the two secrets)

| var | source | value |
| --- | --- | --- |
| `PORT` | Deployment env | `8080` |
| `SITE_ID` | Deployment env | `central` |
| `REPORTING_SITES` | ConfigMap | `tervuren` (comma-separated; add sites here) |
| `REPORTING_TZ` | ConfigMap | `Europe/Brussels` |
| `REPORTING_REFRESH_SECONDS` | ConfigMap | `60` |
| `INFLUX_URL` / `INFLUX_ORG` / `INFLUX_BUCKET` | ConfigMap | `http://influxdb-influxdb2.influxdb` / `zeus` / `zeus` |
| `INFLUX_TOKEN` | **reused** `jupiter-influx` secret | admin all-access token |
| `MQTT_ENABLED` / `MQTT_HOST` / `MQTT_PORT` / `MQTT_KEEPALIVE_SECONDS` / `MQTT_CLIENT_ID` | ConfigMap | `true` / `mqtt.lab.local` / `1883` / `60` / `reporting-central` |
| `MQTT_USER` / `MQTT_PASS` | `jupiter-reporting-secrets` secret | new EMQX `reporting` user |

`PLAN_STALE_AFTER_S` is a module constant in `consumer.py` (900s), **not**
env-driven — there is no knob for it in the chart.

### Secrets — one reused, one new

- **InfluxDB token: REUSED, no new seal.** reporting `envFrom`s the existing
  `jupiter-influx` secret (same namespace, key `INFLUX_TOKEN`) that the forecast
  trainer already uses. That token is the InfluxDB **admin all-access** token —
  verified 2026-07-06 as the ONLY token with read+write on the `zeus` bucket
  (InfluxDB has exactly two tokens: admin all-access, and a `homeassistant`
  write-only-to-`homeassistant`-bucket token). reporting needs read
  (`zeus_state`/`zeus_savings`) + write (`jupiter_state`/`jupiter_daily_savings`)
  on `zeus`, all covered. Reuse works precisely because reporting shares the
  namespace and references the same secret name (SealedSecrets are
  namespace+name scoped).
- **MQTT creds: NEW.** A new subscribe-only EMQX user `reporting` is required —
  none of the existing users is a central subscriber (`cell-tervuren` is a
  per-site publisher; `zeus-mqtt` / `homeassistant` / `mqtt-admin` are
  unrelated). Its creds go in the new `jupiter-reporting-secrets` SealedSecret
  (keys `MQTT_USER` / `MQTT_PASS`). The **owner step** (mint the EMQX user +
  seal the creds) is documented in
  [`.config/lab/jupiter-central.yaml`](../../.config/lab/jupiter-central.yaml);
  the DR-mirror ACL is already added to
  [`platform/mqtt/files/acl.conf`](../../platform/mqtt/files/acl.conf) and the
  runbook table in [`platform/mqtt/README.md`](../../platform/mqtt/README.md).
  ACL: `allow subscribe jupiter/+/plan`, `allow subscribe jupiter/+/heartbeat`,
  `deny all #`.

### Network policy

`reporting-service` gets an ingress-only CiliumNetworkPolicy (repo convention):
inbound limited to `observability` (Prometheus scrape) + the node host
(`/healthz` probes) on port 8080; **egress stays fully open** so it reaches the
EMQX VIP (`mqtt.lab.local:1883`, off-cluster) and in-cluster InfluxDB
(`influxdb-influxdb2.influxdb:80`). An egress lockdown is a human-reviewed
**opt-in** (`reporting.networkPolicy.egress.enabled`, default `false`) with both
destinations pre-wired, so flipping it on is a value-only change.

## Argo CD

Application `jupiter-central`
([applications/templates/jupiter-central/](../../applications/templates/jupiter-central/)),
project `landing-zones`, sync-wave **20** — after the platform layer
(sealed-secrets, cilium, mqtt at 16) and before the zeus landing zone (30),
so the price API exists before any consumer that might be flipped onto it.
