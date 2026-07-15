# influxdb-config

Companion Helm chart for the upstream **`influxdb2`** chart (influxdata,
`2.1.2`) that runs the cluster's InfluxDB 2.x time-series store. The `influxdb2`
chart itself is deployed by the Argo `influxdb` Application
(`applications/templates/influxdb/influxdb-app.yaml`, sync-wave 18) with values
from `.config/lab/influxdb.yaml`; **this** chart supplies everything around it.

InfluxDB is the durable store for zeus savings/forecast history, jupiter LAR
reporting, and long-term HA sensor history. Org `zeus`; buckets `zeus` and
`homeassistant` (both **infinite** retention). Service
`influxdb-influxdb2.influxdb:80`, pod `influxdb-influxdb2-0`.

## What this chart ships

| Template | Resource | Purpose |
|---|---|---|
| `sealed-secret.yaml` | `SealedSecret influxdb-auth` | Admin `admin-password` + `admin-token`, consumed by the `influxdb2` chart's `adminUser.existingSecret`. Encrypted values are per-env in `.config/<env>/influxdb-config.yaml`. |
| `certificate.yaml` | `Certificate influxdb-server-tls` | lab-CA cert so HA (off-cluster) can write over the shared gateway at `influxdb.lab.local`. |
| `backup.yaml` | PVC `influxdb-backups` (`smb`) + 2 CronJobs | **Nightly full** `influx backup` (03:30, 14 d retain) + **hourly incremental** CSV export (75-min overlap window, 3 d retain) for `zeus`,`homeassistant`, both to the DS918 NAS. |
| `servicemonitor.yaml` | `ServiceMonitor influxdb` | Scrapes InfluxDB's `/metrics` (write/query/cardinality/compaction/heap) for the health dashboard. |

Values: [`values.yaml`](values.yaml) (chart defaults) overlaid by
`.config/<env>/influxdb-config.yaml` (sealed data) — see the [Argo app](../../applications/templates/influxdb-config/influxdb-config-app.yaml).

## Storage & the Longhorn migration (card #182)

The InfluxDB **data** PVC (`influxdb-influxdb2`, `10Gi`) is a **standalone
Helm-managed PVC** (not a StatefulSet volumeClaimTemplate) mounted into the STS
by claim name. It currently lives on **`local-path`**, node-pinned to
`k3s-node03` — no restore path if that node/disk dies (the #175 failure class).

Owner request #182 moves it to **`longhorn`** (3 replicas, survives a node/disk
loss). Investigation found the real dataset is **~80 MiB** growing **~5 MiB/day**
(the kubelet "used" stat of ~24 GiB is node03's whole root fs, a local-path
artifact) — so the migration is fast and the replica cost (~30 GiB provisioned,
~1.7 % of the Longhorn pool) is trivial.

- The migration is **owner-scheduled and release-gated** — it is NOT triggered by
  merging this repo. `.config/lab/influxdb.yaml` keeps `storageClass: local-path`
  active with the `longhorn` target documented-but-commented, because flipping it
  alone would only error (immutable `storageClassName` on a bound PVC) and move no
  data.
- Full procedure, rollback, and downtime/write-gap analysis:
  [`RUNBOOK-longhorn-migration.md`](RUNBOOK-longhorn-migration.md).
- **Sequencing:** the `hermes-cortana-state` phase-3 pilot proves the runbook
  first; InfluxDB goes after. See [`docs/storage.md`](../../docs/storage.md).
- The NAS backup CronJobs **stay regardless** — Longhorn replication is
  redundancy, not backup.

## Runbooks

- [`RUNBOOK-longhorn-migration.md`](RUNBOOK-longhorn-migration.md) — move the data
  PVC to Longhorn (this card, #182).
- [`RUNBOOK-site-id-backfill.md`](RUNBOOK-site-id-backfill.md) — one-shot re-tag of
  the frozen untagged zeus archive with `site_id=tervuren` (ADR-0019).
