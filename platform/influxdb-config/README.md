# influxdb-config

Companion Helm chart for the upstream **`influxdb2`** chart (influxdata,
`2.1.2`) that runs the cluster's InfluxDB 2.x time-series store. The `influxdb2`
chart itself is deployed by the Argo `influxdb` Application
(`applications/templates/influxdb/influxdb-app.yaml`, sync-wave 18) with values
from `.config/lab/influxdb.yaml`; **this** chart supplies everything around it —
including, since card #290, the **long-term telemetry archive**.

InfluxDB is the **archive of record** for every project's telemetry
([ADR-0002](../../docs/adr/0002-all-telemetry-in-influxdb-forever.md), owner
decision 2026-09-11): org `zeus`, **every bucket at infinite retention**,
declared and reconciled from `values.yaml` `buckets.list`:

| Bucket | Writers | Content |
|---|---|---|
| `zeus` | jupiter reporting + forecast services (direct line protocol, `site_id`-tagged); zeus (frozen since #169) | battery state, savings, load history, forecasts |
| `homeassistant` | Home Assistant's InfluxDB integration (off-cluster, via the gateway) | every HA entity, unfiltered |
| `ceres` | `ceres-telegraf` ([`landingzones/ceres`](../../landingzones/ceres/README.md)) | every unit's v2 MQTT tree: sensors, actuator state, and the documents (decisions, ledger, alerts, advice, dose results) verbatim |
| `pomona` | nobody (its writer `landingzones/pomona` went with ceres #295 step 5) | the tower's v1 history, 2026-08-31 → 2026-09-15. Was created with 365 d; the reconciler raises it to infinite |
| `prometheus` | **telemetry-archive** (this chart) ← kube-prometheus-stack `remote_write` | the Prometheus series of the project namespaces (`jupiter-*`, `ceres`, `zeus`, `hermes`, `influxdb`), minus what Kubernetes says about them |
| `mqtt` | **telemetry-archive** (this chart) ← EMQX `jupiter/#`, `zeus/#` — **off until the owner enables it** | every MQTT message on those trees, verbatim (plan/heartbeat/schedule documents get a history) |

Service `influxdb-influxdb2.influxdb:80`, pod `influxdb-influxdb2-0`.

## What this chart ships

| Template | Resource | Purpose |
|---|---|---|
| `sealed-secret.yaml` | `SealedSecret influxdb-auth` | Admin `admin-password` + `admin-token`, consumed by the `influxdb2` chart's `adminUser.existingSecret`. Encrypted values are per-env in `.config/<env>/influxdb-config.yaml`. |
| `certificate.yaml` | `Certificate influxdb-server-tls` | lab-CA cert so HA (off-cluster) can write over the shared gateway at `influxdb.lab.local`. |
| `buckets-cronjob.yaml` | `CronJob influxdb-buckets` | **Bucket + retention reconciler** (#290): hourly at :20, creates any bucket in `buckets.list` that is missing and (re)applies the declared retention (`"0"` = forever) to the ones that exist. Never deletes, never touches an unlisted bucket. Drift from a hand-run `influx bucket create --retention …` is corrected within the hour. |
| `archive-*.yaml` | `Deployment`, `Service`, `ConfigMap`, `ServiceMonitor`, `CiliumNetworkPolicy` `telemetry-archive` (+ `SealedSecret telemetry-archive-mqtt` once sealed) | **The archiving service** (#290): a Telegraf receiving Prometheus `remote_write` on `:8080/receive` → bucket `prometheus`, and (once its broker user is sealed and the switch is flipped) subscribing to the project MQTT trees → bucket `mqtt`. Writes with the admin token from `influxdb-auth` (same precedent as the backups). |
| `backup.yaml` | PVC `influxdb-backups` (`smb`) + 2 CronJobs | **Nightly full** `influx backup` (03:30, 14 d retain — every bucket) + **hourly incremental** CSV export (75-min overlap window, 3 d retain) for the buckets in `backup.incremental.buckets`, both to the DS918 NAS. Backups are disaster recovery, not the archive — the archive is the live bucket. |
| `servicemonitor.yaml` | `ServiceMonitor influxdb` | Scrapes InfluxDB's `/metrics` (write/query/cardinality/compaction/heap) for the health dashboard. |

Values: [`values.yaml`](values.yaml) (chart defaults) overlaid by
`.config/<env>/influxdb-config.yaml` (sealed data + the archive's env switches)
— see the [Argo app](../../applications/templates/influxdb-config/influxdb-config-app.yaml).

## The telemetry archive (card #290)

```
Prometheus (observability, 15 d)                    EMQX (mqtt.lab.local)
   │ remote_write, project namespaces only             │ jupiter/#, zeus/#   [OFF until enabled]
   ▼                                                    ▼
telemetry-archive  (Telegraf, ns influxdb, 1 replica) ──────► InfluxDB
   :8080/receive   :9273/metrics                              bucket prometheus / bucket mqtt
```

### Data model

- **`prometheus` bucket, measurement `prometheus`** — one *field* per metric
  name, every Prometheus label a *tag* (`namespace`, `job`, `pod`, `site_id`,
  `unit`, …). Flux:
  `filter(fn: (r) => r._measurement == "prometheus" and r._field == "jupiter_lar_plan_cost_eur")`.
- **`mqtt` bucket, measurement `mqtt`** — string field `value` = the payload
  verbatim, tag `topic` always, tags `project`/`site`/`doc` for three-level
  topics (`jupiter/tervuren/plan`). Retained messages replay on every
  reconnect → one duplicate point per retained topic at reconnect time.
- The Ceres tree is **not** archived here — `ceres-telegraf` owns `ceres/#`
  and the `ceres` bucket ([`landingzones/ceres`](../../landingzones/ceres/README.md)).

### What is archived, and where that is decided

The receiver keeps everything it is sent. **What** is sent is decided on the
Prometheus side, in `.config/<env>/observability.yaml` →
`prometheus.prometheusSpec.remoteWrite[0].writeRelabelConfigs`:

1. **keep** series whose `namespace` label is a project namespace:
   `jupiter-.*|ceres|zeus|hermes|influxdb`;
2. **drop** what Kubernetes says *about* those namespaces: `kube_*`,
   `container_*`, the recording rules derived from them, `prober_*`.

Measured on 2026-10-05, that is about **1 900 series** every 30 s: ~1 250 from
InfluxDB's own `/metrics`, ~390 ceres, ~250 jupiter, a handful hermes/zeus.
Cluster and platform namespaces (kube-system, Longhorn, Cilium, Argo, the
observability stack, the broker) are deliberately not archived. Widening or
narrowing is a one-line change to the keep regex.

### What happens when a piece is missing

| Missing | Effect | Recovers |
|---|---|---|
| telemetry-archive pod | Prometheus keeps scraping, alerting and serving queries; its remote-write queue retries and, after ~2 h, drops the samples that have left the WAL. `PrometheusRemoteStorageFailures` / `PrometheusRemoteWriteBehind` fire. | by itself when the pod is back; the gap stays a gap in the archive (Prometheus still has it for 15 d) |
| InfluxDB | Telegraf buffers ~50 min of samples (`metric_buffer_limit`), then drops the oldest. | by itself |
| bucket `prometheus` (first hour after the first release) | writes are refused until the reconciler has created it | run the reconciler by hand, see owner steps |
| MQTT broker / wrong credentials (only once the MQTT half is on) | the whole Telegraf can fail to start — **the remote_write half goes down with it**. Enable the MQTT half in a watched window. | fix the credentials or flip `archive.mqtt.enabled` back |

### Network policy

`CiliumNetworkPolicy telemetry-archive` selects **only** the telemetry-archive
pod and is ingress-only: it admits the `observability` namespace on `8080`
(remote_write) and `9273` (scrape); egress stays open. No other pod in the
namespace is selected, and the namespace has no other policy, so InfluxDB's own
reachability is unchanged. Off switch: `archive.networkPolicy.enabled: false`.

### Adding a bucket

One entry in `buckets.list`; the CronJob creates it within the hour (or now:
`kubectl -n influxdb create job --from=cronjob/influxdb-buckets buckets-now`).
Add it to `backup.incremental.buckets` too if it should be in the hourly export.
A writer outside this namespace additionally needs an owner-minted scoped token
(tokens cannot be declared in git).

## Owner steps after the first release that carries #290

Nothing here is done by merging; all of it is by hand, in this order.

1. **Create the buckets now instead of waiting for :20.**
   ```sh
   kubectl -n influxdb create job --from=cronjob/influxdb-buckets buckets-now
   kubectl -n influxdb logs job/buckets-now
   ```
   Expect one line per bucket and a closing table: `zeus`, `homeassistant`,
   `ceres` unchanged at infinite; **`pomona` 8760h → infinite**; `prometheus`
   and `mqtt` created. The script has been rendered and dry-run against the API
   server but **never run against InfluxDB** — read this first log.
2. **Check the archive is receiving.**
   ```sh
   kubectl -n influxdb get pods -l app.kubernetes.io/name=telemetry-archive
   kubectl get cnp -n influxdb telemetry-archive        # VALID must be True
   ```
   In Prometheus: `prometheus_remote_storage_samples_failed_total{remote_name="telemetry-archive"}`
   stays flat, `prometheus_remote_storage_samples_total` climbs, and
   `internal_write_metrics_written{output="influxdb_v2"}` from the archive
   climbs with it. In InfluxDB the `prometheus` bucket has points.
3. **After one week, write the real growth on card #290.** The data PVC
   (`influxdb-influxdb2`, 10 Gi) held ~510 MiB on 2026-10-05; the estimate for
   the archive is on the order of 10 MB/day (see the ADR). If it is much more,
   narrow the keep regex (InfluxDB's own `/metrics` is two thirds of it) or grow
   the PVC.
4. **Optional, when wanted: the MQTT document archive** — next section.

## Owner runbook — enabling the MQTT document archiver (one-time)

The remote_write half needs nothing from the owner. The MQTT half authenticates
to EMQX with a dedicated **subscribe-only** user that cannot be created from
git:

1. **EMQX user `telemetry-archive`** — per
   [`platform/mqtt/README.md`](../mqtt/README.md) "Per-client user management":
   create the user, then the mnesia rules `subscribe jupiter/#`,
   `subscribe zeus/#`, `deny all #`. Its `files/acl.conf` mirror lines are
   **deliberately not in git yet** (that edit rolls the brokers) — see
   "Also held out: `telemetry-archive`" there.
2. **Seal the credentials** (namespace + name scoped):
   ```sh
   printf '%s' "$VALUE" | kubeseal --raw \
     --controller-name sealed-secrets --controller-namespace argocd \
     --namespace influxdb --name telemetry-archive-mqtt --from-file=/dev/stdin
   ```
   once for `MQTT_USER` and once for `MQTT_PASS`, into
   `.config/<env>/influxdb-config.yaml` under
   `archive.mqtt.secret.sealedSecret.encryptedData`.
3. Flip `archive.mqtt.enabled: true` in the same file and release. Do it in a
   watched window: a refused login can stop the whole Telegraf, and with it the
   remote_write half (table above). Roll back by flipping the switch.

## Storage & the Longhorn migration (card #182)

The InfluxDB **data** PVC (`influxdb-influxdb2`, `10Gi`) is a **standalone
Helm-managed PVC** (not a StatefulSet volumeClaimTemplate) mounted into the STS
by claim name. It lives on **`longhorn`** since the #235 migration window
(2026-08-14; 3 replicas, survives a node/disk loss — before that `local-path`
pinned to `k3s-node03`, the #175 failure class). The dataset was ~80 MiB
growing ~5 MiB/day at migration time and ~510 MiB on 2026-10-05; #290 adds the
`prometheus` and `mqtt` archives with no retention, so the PVC is a **watch
item** on the InfluxDB health dashboard — grow it before it is tight.

- Full procedure, rollback, and downtime/write-gap analysis:
  [`RUNBOOK-longhorn-migration.md`](RUNBOOK-longhorn-migration.md).
- The NAS backup CronJobs **stay regardless** — Longhorn replication is
  redundancy, not backup. Every nightly full now also carries the `prometheus`
  bucket, so the fulls grow with it (14 are kept).

## Runbooks

- [`RUNBOOK-longhorn-migration.md`](RUNBOOK-longhorn-migration.md) — move the data
  PVC to Longhorn (card #182).
- [`RUNBOOK-site-id-backfill.md`](RUNBOOK-site-id-backfill.md) — one-shot re-tag of
  the frozen untagged zeus archive with `site_id=tervuren` (ADR-0019).
