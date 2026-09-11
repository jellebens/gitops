# ADR-0002: All telemetry is archived in InfluxDB, forever — git-reconciled buckets + the telemetry-archive service

- **Status:** Accepted (2026-09-11). Second ADR in the gitops series (cross-cutting cluster/landing-zone decisions, see [ADR-0001](0001-cortana-model-gpt-5.6-terra.md)). Each project records its own consequences: demeter ADR-0006, pomona ADR-0001, jupiter ADR-0026, home-assitant ADR-0001; zeus's frozen log points here via its index. Extends gitops `docs/designs/199-historical-data-preservation.md` and zeus/jupiter ADR-0009 (InfluxDB as the durable store), ADR-0010 (durable reports on InfluxDB, live ops on Prometheus), jupiter ADR-0024 (retain, never delete).
- **Decided:** 2026-09-11 (owner, card #290), the first evening Demeter's learning curve was needed and found to live only in 15-day Prometheus. Sources: as-built `landingzones/pomona/templates/configmap.yaml`, `platform/influxdb-config/{values.yaml,README.md,RUNBOOK-site-id-backfill.md}`, `.config/lab/{observability,influxdb,pomona}.yaml`, the demeter `docs/adr/` series, the jupiter `docs/ARCHITECTURE.md` §5 topic contract.
- **Deciders:** Jelle (owner), with Claude
- **Tags:** influxdb, telemetry, retention, archive, prometheus, mqtt, telegraf, model-training, backups

## Context

The homelab runs controllers that learn — Demeter doses the hydroponics tower
from a Bayesian dose-response model, jupiter's lar plans the battery from a
trained load forecast, and more of the same is coming. Every one of them is
trained on history. On 2026-09-11 an audit of where that history actually
lived found three classes of loss:

1. **Prometheus is a 15-day window.** kube-prometheus-stack keeps `retention:
   15d` and has no `remote_write`, Thanos or Mimir. Everything that exists only
   as a Prometheus series is gone after two weeks: all of Demeter's learned
   state (`demeter_ph_sensitivity_*`, `demeter_learned_settle_seconds`,
   `demeter_learned_rebound_ph_per_hour`, doses and ml per reagent — 45
   series), everything the live battery controller emits (`jupiter_lar_*`,
   the lar writes nothing to InfluxDB), the price and forecast services,
   Telegraf's own health.
2. **MQTT retains exactly one message per topic.** Documents a controller
   overwrites every cycle — Demeter's decision and ledger, jupiter's `plan`
   (the whole charge/discharge horizon) and `heartbeat` (degraded flags,
   guard state), zeus's schedule — have no history at all. The dose result
   lines on `pomona/dose/result` were not ingested anywhere.
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
   `"0"`. A finite retention on any telemetry bucket requires superseding this
   ADR. Storage is bought, not traded for history.
2. **Buckets and retention are reconciled from git.** The `influxdb-buckets`
   CronJob (hourly) creates a missing bucket and re-applies the declared
   retention to an existing one, idempotently, never deleting. It is a
   CronJob rather than an Argo sync hook because this chart syncs at wave 17,
   before the database exists on a fresh cluster. `pomona` goes from 8760h to
   infinite on its first run. Tokens stay owner-minted (they cannot be
   declared in git) — a runbook step, no longer a bucket step.
3. **A single archiving service, `telemetry-archive`, lives next to the
   database** (`platform/influxdb-config`, namespace `influxdb`): one Telegraf
   with
   - a **Prometheus `remote_write` receiver** → bucket `prometheus`.
     kube-prometheus-stack ships every series from the project namespaces
     (`jupiter-*`, `pomona`, `zeus`, `hermes`, `influxdb`) and drops `kube_*` /
     `container_*`. Measurement `prometheus`, one field per metric name, every
     label a tag. Prometheus itself stays at 15 d — it is the live-ops store
     (ADR-0010), the archive is InfluxDB.
   - an **MQTT document archiver** → bucket `mqtt`: subscribe-only on
     `jupiter/#` and `zeus/#`, every message stored verbatim as a string field
     with the topic as a tag. Off until the owner seals the broker user
     `telemetry-archive` (Telegraf exits if the broker refuses it).
   It authenticates to InfluxDB with the admin token from `influxdb-auth`, the
   precedent set by the backup CronJobs for platform services co-located with
   the database.
4. **Project bridges archive their control plane, not just their sensors.**
   The pomona Telegraf now ingests every remaining `pomona/#` topic verbatim
   (`pomona_events`: dose commands and results, Demeter decision/ledger/
   status/mode, pump/light/control requests and reasons, OTA results, I2C
   scans) plus Demeter's decision and ledger **parsed** into typed
   measurements (`demeter_decision`, `demeter_model`) so the learning curve is
   queryable in Flux without JSON parsing. Verbatim first, parsed second: the
   raw string is the lossless record, the parsed view is a convenience that
   can be rebuilt.
5. **What is deliberately NOT archived:** cluster and platform metrics
   (`kube_*`, `container_*`, node-exporter, Longhorn, Cilium, Kyverno —
   volume, not value, on a 10 Gi PVC), logs, and traces (Jaeger drops on
   overflow by design). Widening is a one-line change to the
   `writeRelabelConfigs` keep-list.
6. **Backups remain disaster recovery, not the archive.** The archive of
   record is the live bucket (design 199). New buckets are added to
   `backup.incremental.buckets` in the same change that declares them.

## Consequences

- **Model training has a complete record from 2026-09-11 onward** — every
  Demeter decision with its reason, every learned parameter every minute,
  every jupiter plan document, every dose. Nothing before that date can be
  recovered for the Prometheus-only series; the pomona sensor history since
  2026-08-31 and the zeus/jupiter/HA archives are intact.
- **Storage grows.** Rough order: the project namespaces emit ~1–2 k series
  at 30 s, which InfluxDB's TSM compresses to the order of 10 MB/day;
  `pomona_events` and the parsed Demeter measurements add a few MB/day;
  jupiter's plan documents ~100 kB/day. The 10 Gi data PVC has years of
  headroom at that rate, but it is a **watch item** on the InfluxDB health
  dashboard, and the first week's real number goes on card #290.
- **Cardinality is bounded by the keep-list**, not by the receiver. Adding a
  namespace to the keep-list is a deliberate act; `zeus_daily_savings_eur{date}`
  and `zeus_price_today_eur_per_kwh{slot}`-style per-date/per-slot series are
  already in the `zeus` namespace and are accepted as-is (zeus is at 0
  replicas).
- **Retained-topic replays produce duplicates.** Telegraf's MQTT consumers get
  every retained message again on reconnect: one extra point per retained
  topic at reconnect time in `pomona_events` and `mqtt`. `demeter_decision`
  is immune (its point time is the document's own `ts`, so a replay rewrites
  the same point). Consumers of the string archives should `distinct()` or
  window; this is cheaper than session tracking.
- **The admin token is used by a second workload.** Accepted for a platform
  service in the database's own namespace; the alternative (an owner-minted
  scoped token per archive bucket, sealed) is a runbook step the owner can
  take at any time by adding a sealed secret and pointing the deployment at
  it. Revisit if InfluxDB ever hosts a non-owner tenant.
- **Owner steps (one-time):** create the subscribe-only EMQX user
  `telemetry-archive` (DR mirror already in `platform/mqtt/files/acl.conf`),
  seal its credentials into `.config/lab/influxdb-config.yaml`, flip
  `archive.mqtt.enabled`. Until then only the remote_write half runs. After
  the first release, confirm `influx bucket list` shows retention 0 for all
  five buckets (the CronJob runs at :20) and that the `prometheus` bucket is
  receiving (`telemetry-archive` internal metrics on the InfluxDB dashboard).
- **Per-landing-zone Prometheus scraping into InfluxDB is unnecessary** now
  and should not be added: `remote_write` covers every ServiceMonitor'd app.
- **Revisit trigger:** if training needs queries *inside* the archived
  documents (plan slot arrays, ledger dose lists) or versioned model
  artifacts, the answer is an object store for artifacts plus Parquet exports
  from InfluxDB, not a second database. MongoDB was considered and declined on
  2026-09-11 (below).

## Alternatives considered

- **Thanos / Mimir / VictoriaMetrics for long-term Prometheus.** Rejected: a
  second time-series store with its own retention, backup and dashboards
  next to the one the owner already backs up nightly. InfluxDB is the
  durable store by ADR-0009; the archive belongs in it.
- **Raise Prometheus retention to years.** Rejected: Prometheus is the
  live-ops store (ADR-0010), cannot hold future-dated forecasts (ADR-0007),
  and its 25 Gi PVC would carry every cluster series too.
- **Per-landing-zone Telegraf `inputs.prometheus` scrapes** (the pomona
  bridge scraping Demeter's `:9000`). Rejected: N configs, N network-policy
  holes, and it forgets every app that only has a ServiceMonitor. One
  `remote_write` covers them all.
- **Prometheus `remote_write` straight into InfluxDB.** Not possible: InfluxDB
  2.x OSS has no Prometheus remote-write endpoint (1.x did). Telegraf's
  `prometheusremotewrite` parser is the bridge.
- **MongoDB for the JSON documents.** Declined for now: the documents fit a
  string field (64 kB limit; the largest, Demeter's 24 h ledger, is ~10 kB),
  get a timestamp for free, and land in the same backup. A document database
  earns its place only for queries inside documents or artifact versioning —
  see the revisit trigger.
- **An Argo `PostSync` hook Job for buckets.** Rejected: fails on a fresh
  cluster because the database (wave 18) does not exist when this chart
  (wave 17) syncs; the hourly CronJob simply retries.
- **Finite retention on the new archive buckets.** Rejected by the owner:
  history is the point.
