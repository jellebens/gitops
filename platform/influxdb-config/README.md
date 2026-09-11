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
| `pomona` | `landingzones/pomona` Telegraf bridge | tower sensors + the whole dosing control plane (Demeter decisions, ledger/model, dose events, pump/light requests) |
| `prometheus` | **telemetry-archive** (this chart) ← kube-prometheus-stack `remote_write` | every Prometheus series from the project namespaces (`jupiter-*`, `pomona`, `zeus`, `hermes`, `influxdb`), minus `kube_*`/`container_*` |
| `mqtt` | **telemetry-archive** (this chart) ← EMQX `jupiter/#`, `zeus/#` | every MQTT message on the project trees, verbatim (plan/heartbeat/schedule documents get a history) |

Service `influxdb-influxdb2.influxdb:80`, pod `influxdb-influxdb2-0`.

## What this chart ships

| Template | Resource | Purpose |
|---|---|---|
| `sealed-secret.yaml` | `SealedSecret influxdb-auth` | Admin `admin-password` + `admin-token`, consumed by the `influxdb2` chart's `adminUser.existingSecret`. Encrypted values are per-env in `.config/<env>/influxdb-config.yaml`. |
| `certificate.yaml` | `Certificate influxdb-server-tls` | lab-CA cert so HA (off-cluster) can write over the shared gateway at `influxdb.lab.local`. |
| `buckets-cronjob.yaml` | `CronJob influxdb-buckets` | **Bucket + retention reconciler** (#290): hourly, creates any bucket in `buckets.list` that is missing and (re)applies the declared retention (`"0"` = forever) to the ones that exist. Never deletes. Drift from a hand-run `influx bucket create --retention …` is corrected within the hour. |
| `archive-*.yaml` | `Deployment/Service/ConfigMap/ServiceMonitor/CiliumNetworkPolicy telemetry-archive` (+ optional `SealedSecret telemetry-archive-mqtt`) | **The archiving service** (#290): a Telegraf receiving Prometheus `remote_write` on `:8080/receive` → bucket `prometheus`, and (once its broker user is sealed) subscribing to the project MQTT trees → bucket `mqtt`. Writes with the admin token from `influxdb-auth` (same precedent as the backups). |
| `backup.yaml` | PVC `influxdb-backups` (`smb`) + 2 CronJobs | **Nightly full** `influx backup` (03:30, 14 d retain) + **hourly incremental** CSV export (75-min overlap window, 3 d retain) for every bucket in `backup.incremental.buckets`, both to the DS918 NAS. Backups are disaster recovery, not the archive — the archive is the live bucket. |
| `servicemonitor.yaml` | `ServiceMonitor influxdb` | Scrapes InfluxDB's `/metrics` (write/query/cardinality/compaction/heap) for the health dashboard. |

Values: [`values.yaml`](values.yaml) (chart defaults) overlaid by
`.config/<env>/influxdb-config.yaml` (sealed data + the archive's env switches)
— see the [Argo app](../../applications/templates/influxdb-config/influxdb-config-app.yaml).

## The archive data model

- **`prometheus` bucket, measurement `prometheus`** — one *field* per metric
  name, every Prometheus label a *tag* (`namespace`, `job`, `pod`,
  `site_id`, `reagent`, …). Flux: `filter(fn: (r) => r._measurement == "prometheus" and r._field == "demeter_ph_sensitivity_ph_per_ml")`.
  What is shipped is decided on the Prometheus side
  (`.config/<env>/observability.yaml` → `prometheusSpec.remoteWrite[].writeRelabelConfigs`):
  keep by `namespace`, drop `kube_*` / `container_*`. Widening the archive is a
  one-line change there; the receiver keeps everything it is sent.
- **`mqtt` bucket, measurement `mqtt`** — string field `value` = the payload
  verbatim, tag `topic` always, tags `project`/`site`/`doc` for three-level
  topics (`jupiter/tervuren/plan`). Retained messages replay on every
  reconnect → one duplicate point per retained topic at reconnect time.
- `pomona` bucket — see [`landingzones/pomona/README.md`](../../landingzones/pomona/README.md)
  "Data model" (`pomona`, `pomona_meta`, `pomona_events`, `demeter_decision`,
  `demeter_model`).

Adding a bucket = one entry in `buckets.list` **and** one in
`backup.incremental.buckets`; the CronJob creates it within the hour (or run it
now: `kubectl -n influxdb create job --from=cronjob/influxdb-buckets buckets-now`).
A writer outside this namespace additionally needs an owner-minted scoped token
(tokens cannot be declared in git).

## Owner runbook — enabling the MQTT document archiver (one-time)

The remote_write half of telemetry-archive needs nothing from the owner. The
MQTT half authenticates to EMQX with a dedicated **subscribe-only** user that
cannot be created from git:

1. **EMQX user `telemetry-archive`** — per
   [`platform/mqtt/README.md`](../mqtt/README.md) "Per-client user management":
   create the user, then the mnesia ACL `subscribe jupiter/#, zeus/#` + `deny #`.
   The DR mirror is already in [`platform/mqtt/files/acl.conf`](../mqtt/files/acl.conf).
2. **Seal the credentials** (namespace + name scoped):
   ```sh
   printf '%s' "$VALUE" | kubeseal --raw \
     --controller-name sealed-secrets --controller-namespace argocd \
     --namespace influxdb --name telemetry-archive-mqtt
   ```
   for `MQTT_USER` and `MQTT_PASS`, into `.config/<env>/influxdb-config.yaml`
   under `archive.mqtt.secret.sealedSecret.encryptedData`.
3. Flip `archive.mqtt.enabled: true` in the same file and release. (It is off by
   default because Telegraf exits at start when the broker refuses the login.)

## Storage & the Longhorn migration (card #182)

The InfluxDB **data** PVC (`influxdb-influxdb2`, `10Gi`) is a **standalone
Helm-managed PVC** (not a StatefulSet volumeClaimTemplate) mounted into the STS
by claim name. It lives on **`longhorn`** since the #235 migration window
(2026-08-14; 3 replicas, survives a node/disk loss — before that `local-path`
pinned to `k3s-node03`, the #175 failure class). The dataset was ~80 MiB
growing ~5 MiB/day at migration time; #290 adds the `prometheus` and `mqtt`
archives (app series only — see the ADR for the volume reasoning), so watch
the PVC on the InfluxDB health dashboard and grow it before it is tight.

- Full procedure, rollback, and downtime/write-gap analysis:
  [`RUNBOOK-longhorn-migration.md`](RUNBOOK-longhorn-migration.md).
- The NAS backup CronJobs **stay regardless** — Longhorn replication is
  redundancy, not backup.

## Runbooks

- [`RUNBOOK-longhorn-migration.md`](RUNBOOK-longhorn-migration.md) — move the data
  PVC to Longhorn (card #182).
- [`RUNBOOK-site-id-backfill.md`](RUNBOOK-site-id-backfill.md) — one-shot re-tag of
  the frozen untagged zeus archive with `site_id=tervuren` (ADR-0019).
