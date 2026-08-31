# Pomona — hydroponic tower (landing zone)

**Vision (card #221):** Pomona is the hydroponics project — an indoor tower
growing fruits, vegetables and herbs, **monitoring-first**: before any
automation ever actuates a pump or a dosing valve, the unit's water chemistry,
climate and reservoir state are measured, ingested, dashboarded and alarmed.
Decisions (nutrient dosing, top-ups, photoperiod) stay with the owner; the
cluster's job is to make them well-informed. Firmware **v1.0.0** is LIVE on an
Arduino GIGA with all v1 sensors connected and calibrated (water temp, EC
K=0.9745, pH 2-point calibrated, 4-point level probe, BME280, BH1750) and
publishes over MQTT with OTA updates proven untethered.

- **Application source:** <https://github.com/jellebens/pomona> (firmware,
  calibration lessons, `docs/mqtt.md` topic schema, OTA/deploy tooling).
- **This directory is ingestion + observability only** — no pomona application
  image runs in-cluster. It ships a **Telegraf bridge** (official multi-arch
  `telegraf` image, arm64-compatible) that subscribes to `pomona/#` on the
  platform EMQX broker and writes to InfluxDB, plus the first Grafana
  dashboard.

## Architecture

```
GIGA firmware ──MQTT (user `pomona`)──> EMQX mqtt.lab.local:1883 (ns mqtt)
                                            │
                              subscribe pomona/# (user `pomona-ingest`)
                                            │
                        pomona-ingest (Telegraf, ns pomona, this chart)
                                            │
                              InfluxDB org zeus / bucket `pomona` (365d)
                                            │
                        Grafana "pomona" folder — dashboards/pomona.json
```

Why Telegraf and not a custom bridge: every other producer here (zeus, the
jupiter services) is an app that writes InfluxDB natively; pomona's producer is
a microcontroller, so the repo needed its first MQTT→Influx bridge. Telegraf's
`mqtt_consumer` + `influxdb_v2` is the boring, battle-tested way to do exactly
that with zero custom code, deployed in the standard landing-zone chart shape
(namespace / configmap / sealed-secret / deployment / CNP / servicemonitor /
dashboard — the zeus pattern).

## How it's deployed

| | |
|---|---|
| Argo CD app | `pomona` (project `landing-zones`, sync-wave `30`) |
| Namespace | `pomona` |
| App definition | [`applications/templates/pomona/pomona-app.yaml`](../../applications/templates/pomona/pomona-app.yaml) |
| Chart | this directory (`landingzones/pomona`) |
| Env values | `.config/shared/values.yaml`, `.config/<env>/values.yaml`, `.config/<env>/pomona.yaml` (multi-source `$values`) |

Argo syncs automatically (`prune`, `selfHeal`, `CreateNamespace=true`,
`ServerSideApply=true`). Changes deploy only when a release merges to `master`.

## Data model

Topics (live, from pomona `docs/mqtt.md`), ingested as two measurements in the
`pomona` bucket. `topic_parsing` turns `pomona/<zone>/<metric>` into `zone` +
`metric` **tags**; the field is always `value`:

| measurement | zone | metric | type | notes |
|---|---|---|---|---|
| `pomona` | water | `temp_c` | float | reservoir °C |
| `pomona` | water | `ec_ms_cm` | float | EC, K=0.9745 |
| `pomona` | water | `ph` | float | 2-point calibrated |
| `pomona` | water | `ph_raw_v` | float | raw electrode volts (drift diagnosis) |
| `pomona` | water | `level_points` | float | 0–4 probe points wet |
| `pomona` | air | `temp_c` / `humidity_pct` / `pressure_hpa` | float | BME280 @0x77 |
| `pomona` | air | `lux` | float | BH1750, ~1/60 of true canopy lux (rhythm indicator) |
| `pomona` | unit | `rssi_dbm` / `uptime_s` | float | WiFi + uptime |
| `pomona_meta` | unit | `status` | string | `online`/`offline`, retained (LWT) |
| `pomona_meta` | unit | `fw_version` | string | retained |
| `pomona_meta` | unit | `sensors` | string | retained JSON availability map, stored verbatim |

Example Flux:

```flux
from(bucket: "pomona")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "pomona" and r.zone == "water"
      and r.metric == "ec_ms_cm" and r._field == "value")
```

- **Bucket**: `pomona`, org `zeus`, **365d retention** — a full season of
  chemistry/climate history at ~60s cadence is small (same order as zeus's
  ~5 MiB/day total), and a year bounds cardinality growth without ever
  mattering for the current dataset. Included in the hourly incremental NAS
  export (`platform/influxdb-config` `backup.incremental.buckets`; the nightly
  full backup covers all buckets automatically).
- **Broker**: always `mqtt.lab.local:1883` (the EMQX LB VIP), never a pod/node
  IP — [`platform/mqtt/README.md`](../../platform/mqtt/README.md).

## Owner runbook — pre-deploy steps (REQUIRED before the release merges)

The bridge authenticates with a **dedicated least-privilege EMQX user** and a
**scoped InfluxDB token**; neither can be minted from git. Until all three
values are sealed into `.config/<env>/pomona.yaml`, the pod runs but ingests
nothing (envFrom is `optional: true` — deploy order is not blocked).

1. **EMQX user `pomona-ingest`** (do NOT reuse the `pomona` device user) — per
   the runbook in [`platform/mqtt/README.md`](../../platform/mqtt/README.md)
   "Per-client user management", in-cluster against `mqtt-0`:
   - Login → bearer token (`POST /api/v5/login`).
   - Create user: `POST /api/v5/authentication/password_based:built_in_database/users`
     `{"user_id":"pomona-ingest","password":"<pw>","is_superuser":false}`.
   - Scoped ACL (subscribe-only — the bridge publishes nothing):
     `POST /api/v5/authorization/sources/built_in_database/rules/users`
     `[{"username":"pomona-ingest","rules":[{"topic":"pomona/#","permission":"allow","action":"subscribe"},{"topic":"#","permission":"deny","action":"all"}]}]`
   - Mirror the rule into `platform/mqtt/files/acl.conf` + the README table per
     the standing DR rule — fold it into **card #252** (the pomona ACL DR-mirror
     card) so the two pomona users land in the mirror together.
2. **InfluxDB bucket + token** (in-cluster, pod `influxdb-influxdb2-0`, admin
   token from the `influxdb-auth` secret):
   ```sh
   influx bucket create --name pomona --org zeus --retention 8760h
   # scoped token: write-only pomona + read for /api/ds/query verification
   influx auth create --org zeus --description "pomona-ingest bridge" \
     --write-bucket <pomona-bucket-id> --read-bucket <pomona-bucket-id>
   ```
   (Grafana reads via the existing admin token in `grafana-influxdb-token`; no
   Grafana change is needed for the new bucket.)
3. **Seal the three values** (namespace + name scoped):
   ```sh
   printf '%s' "$VALUE" | kubeseal --raw \
     --controller-name sealed-secrets --controller-namespace argocd \
     --namespace pomona --name pomona-secrets
   ```
   Paste the outputs as `MQTT_USER` / `MQTT_PASS` / `INFLUX_TOKEN` under
   `secret.sealedSecret.encryptedData` in `.config/<env>/pomona.yaml`.

## Chart layout

```
templates/
  namespace.yaml            ns pomona
  configmap.yaml            telegraf.conf (2x mqtt_consumer -> influxdb_v2 + prometheus_client)
  sealed-secret.yaml        MQTT_USER / MQTT_PASS / INFLUX_TOKEN (kubeseal; rendered once sealed)
  deployment.yaml           pomona-ingest (Telegraf, single replica, Recreate)
  service.yaml              pomona-metrics ClusterIP :9273
  servicemonitor.yaml       Prometheus scrape (release=kube-prometheus-stack)
  ciliumnetworkpolicy.yaml  ingress-only: observability -> :9273 (zeus pattern)
  dashboard.yaml            Grafana dashboard ConfigMap (globs dashboards/*.json)
dashboards/pomona.json      the Pomona — Hydroponics dashboard
```

## Observability

- **Dashboard** `Pomona — Hydroponics` (uid `pomona`), provisioned by the
  Grafana sidecar into the **`pomona` folder** via the `grafana_folder`
  annotation (mechanism already enabled in `.config/lab/observability.yaml`,
  #127 — unannotated ConfigMaps stay in General, so nothing else moves). The
  InfluxDB **datasource** (uid `influxdb`) is the static-mounted one from
  observability-config — never sidecar-provisioned (boot race + unauthed
  reload 403; known gotcha). All Flux series are named with `rename()`, not
  `set(_field: ...)`.
  - Header stats: unit online/offline, firmware, WiFi RSSI, uptime, reservoir
    state (>=3 OK green / 1–2 WRN amber / 0 CRIT red).
  - EC with shaded targets (0.8–1.0 transplant amber, 1.4–1.6 established
    green), pH with 5.8–6.2 band, water temp, reservoir state timeline,
    lux day/night rhythm, air temp/humidity/pressure, HA-side pump watts.
- **Prometheus**: the ServiceMonitor scrapes Telegraf's `prometheus_client`
  output (`:9273`) — Telegraf self-telemetry (`internal_*`, e.g.
  `internal_gather_metrics_gathered` per input) plus a mirror of the numeric
  pomona series. PrometheusRules (ingest-stalled, reservoir-CRIT, EC/pH
  out-of-band alerts) are a deliberate follow-up once real traffic sets
  baselines.

## Follow-ups

- **Card #252**: mirror the `pomona` (device) + `pomona-ingest` ACLs into
  `platform/mqtt/files/acl.conf` (DR) and reconcile `users.csv`.
- Lamp switch state panel (HA entity id TBD) next to the pump-watts panel.
- PrometheusRule alerts (reservoir CRIT, unit offline, ingest stalled).
- HA ingestion of `pomona/#` (device topics) for automations/notifications is
  the pomona repo's #222 follow-on — this landing zone deliberately ingests
  straight from the broker, not via HA.
