# ADR-0002: All telemetry is archived in InfluxDB, forever — git-reconciled buckets + the telemetry-archive service

- **Status:** Accepted (decided 2026-09-11; re-scoped to the platform half 2026-10-05, see "Re-scope" below). Second ADR in the gitops series (cross-cutting cluster/landing-zone decisions, see [ADR-0001](0001-cortana-model-gpt-5.6-terra.md)). Project-side records: jupiter ADR-0026 and home-assitant ADR-0001 (both still open PRs at the time of writing); Ceres records its own archive in ceres ADR-0006. Extends gitops `docs/designs/199-historical-data-preservation.md` and zeus/jupiter ADR-0009 (InfluxDB as the durable store), ADR-0010 (durable reports on InfluxDB, live ops on Prometheus), jupiter ADR-0024 (retain, never delete).
- **Decided:** 2026-09-11 (owner, card #290), the first evening the hydroponics controller's learning curve was needed and found to live only in 15-day Prometheus. Sources: as-built `platform/influxdb-config/{values.yaml,README.md}`, `.config/lab/{observability,influxdb}.yaml`, `landingzones/ceres/templates/telegraf-deployment.yaml`, the jupiter `docs/ARCHITECTURE.md` §5 topic contract; live readings of 2026-10-05 (Prometheus series counts, `buckets()`).
- **Deciders:** Jelle (owner), with Claude
- **Tags:** influxdb, telemetry, retention, archive, prometheus, mqtt, telegraf, model-training, backups

## Context

The homelab runs controllers that learn — Ceres doses the hydroponics tower
from a dose-response model, jupiter's lar plans the battery from a trained
load forecast, and more of the same is coming. Every one of them is trained on
history. On 2026-09-11 an audit of where that history actually lived found
three classes of loss:

1. **Prometheus is a 15-day window.** kube-prometheus-stack keeps `retention:
   15d` and has no `remote_write`, Thanos or Mimir. Everything that exists only
   as a Prometheus series is gone after two weeks: a dosing controller's
   learned state, everything the live battery controller emits
   (`jupiter_lar_*` — the lar writes nothing to InfluxDB), the price and
   forecast services, Telegraf's own health.
2. **MQTT retains exactly one message per topic.** Documents a controller
   overwrites every cycle — jupiter's `plan` (the whole charge/discharge
   horizon) and `heartbeat` (degraded flags, guard state), zeus's schedule, a
   dosing decision and its ledger — have no history at all unless something
   archives them.
3. **Retention was hand-set and invisible to git.** Only the `zeus` bucket's
   infinite retention is declared (`.config/lab/influxdb.yaml`
   `retention_policy: "0s"`). `homeassistant` was created by hand (infinite),
   `pomona` was created by hand with `--retention 8760h` per a README step.
   There is no declarative bucket mechanism, so a finite retention could age
   data out with nothing in a diff to show it.

What was already right: the `zeus` and `homeassistant` buckets are infinite,
jupiter and zeus write `site_id`-tagged line protocol directly, HA records
every entity unfiltered, and the NAS holds nightly full + hourly incremental
backups. The gap was coverage and enforcement, not the store.

## Decision

1. **InfluxDB is the archive of record for all telemetry, and retention is
   infinite everywhere.** Every bucket in org `zeus` is declared in
   `platform/influxdb-config` `values.yaml` `buckets.list` with retention
   `"0"`: `zeus`, `homeassistant`, `pomona`, `ceres`, `prometheus`, `mqtt`. A
   finite retention on any telemetry bucket requires superseding this ADR.
   Storage is bought, not traded for history.
2. **Buckets and retention are reconciled from git.** The `influxdb-buckets`
   CronJob (hourly) creates a missing bucket and re-applies the declared
   retention to an existing one, idempotently. It never deletes a bucket and
   never touches one that is not listed. It is a CronJob rather than an Argo
   sync hook because this chart syncs at wave 17, before the database exists
   on a fresh cluster. On its first run exactly one existing bucket changes:
   `pomona` goes from 8760h to infinite (the tower's v1 history, which would
   otherwise start ageing out on 2027-08-31). Tokens stay owner-minted (they
   cannot be declared in git).
3. **A single archiving service, `telemetry-archive`, lives next to the
   database** (`platform/influxdb-config`, namespace `influxdb`): one Telegraf
   with
   - a **Prometheus `remote_write` receiver** → bucket `prometheus`.
     kube-prometheus-stack ships the series of the project namespaces
     (`jupiter-*`, `ceres`, `zeus`, `hermes`, `influxdb`) and drops what
     Kubernetes reports *about* them (`kube_*`, `container_*`, the recording
     rules derived from those, `prober_*`). Measurement `prometheus`, one field
     per metric name, every label a tag. Prometheus itself stays at 15 d — it
     is the live-ops store (ADR-0010), the archive is InfluxDB.
   - an **MQTT document archiver** → bucket `mqtt`: subscribe-only on
     `jupiter/#` and `zeus/#`, every message stored verbatim as a string field
     with the topic as a tag. **Off** until the owner creates and seals the
     broker user `telemetry-archive`.
   It authenticates to InfluxDB with the admin token from `influxdb-auth`, the
   precedent set by the backup CronJobs for platform services co-located with
   the database. Its CiliumNetworkPolicy is ingress-only and selects that pod
   alone.
4. **Each project archives its own MQTT control plane, in its own landing
   zone.** That is how Ceres already works: `ceres-telegraf` writes every
   unit's v2 tree to the `ceres` bucket, documents verbatim. The platform
   service does not subscribe to `ceres/#`; it would be a second copy.
5. **What is deliberately NOT archived:** cluster and platform metrics
   (kube-state-metrics, cAdvisor, node-exporter, Longhorn, Cilium, Kyverno,
   Argo, the observability stack and the broker themselves — volume, not
   value, on a 10 Gi PVC), logs, and traces (Jaeger drops on overflow by
   design). Widening is a one-line change to the `writeRelabelConfigs` keep
   regex.
6. **Backups remain disaster recovery, not the archive.** The archive of
   record is the live bucket (design 199). The nightly full covers every
   bucket. The hourly incremental export takes `mqtt` but not `prometheus`:
   75 minutes of ~1 900 series is on the order of 100 MB of CSV per file, and
   Prometheus itself still holds the newest 15 days.

## Re-scope (2026-10-05): what was dropped, and why

The first implementation (gitops PR #362, 2026-09-11) was never merged. By the
time it was picked up again it conflicted in eight files and one of its two
halves had lost its subject:

- **Dropped — the `landingzones/pomona` half.** #362 extended the pomona
  Telegraf bridge to archive the rest of `pomona/#` verbatim
  (`pomona_events`) and to parse the v1 controller's decision and ledger into
  typed measurements (`demeter_decision`, `demeter_model`). That landing zone,
  its controller and the whole `pomona/#` topic tree were retired with ceres
  #295 step 5 (last v1 point 2026-09-15). There is nothing left to subscribe
  to.
- **What replaced it, and what that does and does not cover.** `ceres-telegraf`
  archives the v2 tree to the `ceres` bucket: the numeric telemetry, actuator
  state and reason, and — verbatim — decision, ledger, alerts, advice, config,
  desired and dose result documents. The *typed* decision/model measurements
  were not carried over: the decision and the ledger are there as JSON
  strings (`unit_docs`), to be parsed by whoever reads them. A few v2 topics
  that correspond to things #362 did archive are in neither archive — the
  dose command (`dose/request`), the actuator override (`actuator/+/set`),
  `sys/ota/result` and `sys/diag/#` — along with the newer `sys/prior` and
  `sys/weather`. That is the Ceres workstream's list to judge; it is noted
  here so it is not lost.
- **Gained by the platform half.** The learned model the Vertumnus exposes as
  Prometheus gauges (`ceres_ph_sensitivity_ph_per_ml`,
  `ceres_learned_settle_seconds`, `ceres_learned_rebound_ph_per_hour`, …, the
  direct successors of the `demeter_*` series this card started from) was
  still 15-day only on 2026-10-05. `ceres` took `pomona`'s place in the
  `remote_write` keep regex, so those series — and Carmenta's, Robigus's,
  Annona's and Janus's — are archived from the release on.
- **Changed from #362:**
  - `ceres` is declared in `buckets.list` (it did not exist then; live it is
    already infinite, so this is enforcement, not a change).
  - The drop regex also removes the recording rules derived from `kube_*` /
    `container_*` and the kubelet `prober_*` histograms. #362's regex let
    ~700 such series through per scrape; the stated intent was always "no
    cluster plumbing".
  - Telegraf's own `internal_*` stats are no longer written straight to the
    bucket (the ceres #307 lesson); they arrive once, through Prometheus.
  - `prometheus` is left out of the hourly incremental export (decision 6).
  - The `telemetry-archive` lines are **not** added to
    `platform/mqtt/files/acl.conf`. Any edit to that file rolls all three
    brokers and, with the RAM retainer, drops every retained message — the
    reason `janus` has been held out of it since 2026-09-17
    (`platform/mqtt/README.md`, "Known DR gap"). The user does not
    exist yet, so there is nothing to mirror; the lines go in with the `janus`
    follow-up, one roll for both.
  - The buckets job called `influx bucket update --org …`; that command has no
    `--org` flag, so it would have failed on every existing bucket. It now
    updates by ID only.
  - No chart version is bumped in the change itself; that happens once, at
    release (`influxdb-config` is the only chart whose render changes).

## Consequences

- **Model training has a complete record from the release that carries this
  onward** — every project Prometheus series every 30 s, and, once the MQTT
  half is on, every jupiter plan and heartbeat document. Nothing before that
  date can be recovered for the Prometheus-only series: the three weeks
  between the decision and the release are lost for them. The `ceres`,
  `pomona`, `zeus` and `homeassistant` archives are intact.
- **Storage grows without bound.** Measured on 2026-10-05 the keep/drop rules
  pass about 650 series at 30 s (≈ 1.9 M points/day): ~390 ceres, ~250
  jupiter, a handful hermes/zeus. At a few bytes per compressed point that is
  on the order of 3–4 MB/day, roughly 1 GB per year, against a 10 Gi data PVC
  that held ~510 MiB on that day. The PVC stays a **watch item** on the
  InfluxDB health dashboard, and the first week's real number goes on card
  #290. These are estimates from series counts, not a measured write rate.
- **InfluxDB's own metrics are not archived (owner, 2026-10-05).** The first
  draft kept namespace `influxdb` — ~1 250 series of the database's own
  `/metrics`, two thirds of the volume. The owner dropped it: the historical
  evolution of the database's internals is of no interest. Prometheus keeps
  its usual 15 days of them for alerting and the health dashboard, and that
  includes the telemetry-archive's own `internal_*` stats.
- **Prometheus cannot be stopped by this.** Remote write is a side channel
  off the WAL: with the receiver down or misbehaving, scraping, rules and
  queries carry on, the queue retries, and samples older than the WAL (~2 h)
  are dropped. The stock `PrometheusRemoteStorageFailures` and
  `PrometheusRemoteWriteBehind` alerts then fire, and the watchdog opens a
  card. An invalid `remoteWrite` block is refused at the API (CRD schema) or
  by the operator, both of which leave the running configuration in place.
- **Cardinality is bounded by the keep regex**, not by the receiver. Adding a
  namespace is a deliberate act.
- **Retained-topic replays produce duplicates** in the `mqtt` bucket: one
  extra point per retained topic at each reconnect. Consumers of the string
  archive should de-duplicate on a timestamp inside the document.
- **The two halves share one process.** A broker that refuses the MQTT login
  can stop Telegraf at start, and the remote_write receiver with it. Hence the
  MQTT half is off by default and is switched on in a watched window.
- **The admin token is used by a second workload.** Accepted for a platform
  service in the database's own namespace; the alternative (an owner-minted
  scoped token per archive bucket, sealed) is a runbook step the owner can
  take at any time. Revisit if InfluxDB ever hosts a non-owner tenant.
- **Owner steps** are in `platform/influxdb-config/README.md`: run the buckets
  job once and read its log (the script has not been run against InfluxDB),
  confirm the `prometheus` bucket fills and remote-write failures stay at
  zero, note the PVC growth after a week; optionally create and seal the
  broker user and switch the MQTT half on.
- **Per-landing-zone Prometheus scraping into InfluxDB is unnecessary** and
  should not be added: `remote_write` covers every ServiceMonitor'd app.
- **Revisit trigger:** if training needs queries *inside* the archived
  documents (plan slot arrays, ledger dose lists) or versioned model
  artifacts, the answer is an object store for artifacts plus Parquet exports
  from InfluxDB, not a second time-series database. MongoDB was considered and
  declined on 2026-09-11 (below).

## Alternatives considered

- **Thanos / Mimir / VictoriaMetrics for long-term Prometheus.** Rejected: a
  second time-series store with its own retention, backup and dashboards
  next to the one the owner already backs up nightly. InfluxDB is the
  durable store by ADR-0009; the archive belongs in it.
- **Raise Prometheus retention to years.** Rejected: Prometheus is the
  live-ops store (ADR-0010), cannot hold future-dated forecasts (ADR-0007),
  and its 25 Gi PVC would carry every cluster series too.
- **Per-landing-zone Telegraf `inputs.prometheus` scrapes.** Rejected: N
  configs, N network-policy holes, and it forgets every app that only has a
  ServiceMonitor. One `remote_write` covers them all.
- **Prometheus `remote_write` straight into InfluxDB.** Not possible: InfluxDB
  2.x OSS has no Prometheus remote-write endpoint (1.x did). Telegraf's
  `prometheusremotewrite` parser is the bridge.
- **Let the platform archiver also subscribe to `ceres/#`.** Rejected: Ceres
  already archives its tree with unit-aware tags; a second verbatim copy buys
  nothing.
- **MongoDB for the JSON documents.** Declined for now: the documents fit a
  string field, get a timestamp for free, and land in the same backup. A
  document database earns its place only for queries inside documents or
  artifact versioning — see the revisit trigger.
- **An Argo `PostSync` hook Job for buckets.** Rejected: fails on a fresh
  cluster because the database (wave 18) does not exist when this chart
  (wave 17) syncs; the hourly CronJob simply retries.
- **Finite retention on the new archive buckets.** Rejected by the owner:
  history is the point.
