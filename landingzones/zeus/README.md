# Zeus — Bluetti battery optimizer (landing zone)

Price-aware charge/discharge optimizer for a **Bluetti Apex 300 + 2× B500K**
(~13 kWh, 3.84 kW AC). Zeus forecasts load, optimizes against day-ahead prices
with a PuLP linear program, drives the battery's working mode through Home
Assistant, and reports realized savings back to HA over MQTT.

- **Application source:** <https://github.com/jellebens/zeus> (the Python package,
  `Dockerfile`, tests). This directory is **deployment only** — the Helm chart
  that runs the published image in-cluster.
- **Image:** `jellebens/zeus` on Docker Hub (public). **Must be `linux/arm64`** —
  the k3s cluster is arm64; an amd64 image fails with `ImagePullBackOff: no match
  for platform`.

## How it's deployed

| | |
|---|---|
| Argo CD app | `zeus` (project `landing-zones`, sync-wave `30`) |
| Namespace | `zeus` |
| App definition | [`applications/templates/zeus/zeus-app.yaml`](../../applications/templates/zeus/zeus-app.yaml) |
| Chart | this directory (`landingzones/zeus`) |
| Env values | `.config/shared/values.yaml`, `.config/<env>/values.yaml`, `.config/<env>/zeus.yaml` (multi-source `$values`) |

Argo syncs automatically (`prune: true`, `selfHeal: true`,
`CreateNamespace=true`, `ServerSideApply=true`). Push to `main` → Argo applies.

```sh
argocd app get zeus --core
argocd app sync zeus --core
argocd app wait zeus --core --sync --health --timeout 300
kubectl -n zeus logs deploy/zeus --tail=40
```

## Chart layout

```
templates/
  namespace.yaml        ns zeus
  configmap.yaml        config.yaml rendered from .Values.config
  sealed-secret.yaml    HA_TOKEN / MQTT_* / ENTSOE_TOKEN (kubeseal)
  pvc.yaml              reports + load/A-C history (/app/reports), on NAS001 (smb SC)
  deployment.yaml       the zeus pod (envFrom the secret, mounts config + pvc)
  service.yaml          zeus-metrics ClusterIP :9000
  servicemonitor.yaml   Prometheus scrape (label release=kube-prometheus-stack)
  prometheusrule.yaml   alerts (ZeusDown, ZeusControlUnavailable, ZeusBatteryStateMismatch, …)
  dashboard.yaml        Grafana dashboard ConfigMap (globs dashboards/*.json)
dashboards/*.json       four Grafana dashboard models (see Observability)
```

## Configuration highlights

All runtime config lives under `.Values.config` in [`values.yaml`](values.yaml)
and is rendered verbatim into `/config/config.yaml`. Key choices:

- **Control (LIVE):** `control.enabled: true`, `run.dry_run: false`. Zeus sets
  HA select `select.apex300_working_mode` to `CHARGING` / `DISCHARGING` /
  `PASSTHROUGH`. Mode-based control is self-limiting (sets a mode, not a power
  setpoint). ⚠️ The old HA price automations **must stay disabled** — two
  controllers fighting the battery is bad.
- **Prices:** Nord Pool market price `sensor.nordpool_kwh_be_eur_3_10_006`,
  attribute `raw_today` (+`raw_tomorrow` auto-appended), `price_scale: 0.01`
  (c/kWh → EUR/kWh).
- **Savings (arbitrage model):** the battery only charges from grid and powers
  critical loads (no solar charging, no export), so `reporting.mode: arbitrage`
  computes savings = discharge value − charge cost from `grid_input_power` /
  `ac_output_power`. The house-load/optimizer forecast is advisory in this
  topology.
- **Optimizer:** 36 h horizon, 60 min slots. `cycle_penalty: 0.0` €/kWh of
  throughput — **wear-agnostic, maximize savings** (changed from `0.03` on
  2026-06-28: a live-curve sweep showed `0.03` sat past a cliff — it skipped a
  €0.51/kWh peak and captured ~2.5× less savings; round-trip efficiency ~90%
  still floors pointless cycling). `backup_reserve_pct: 30` — a **soft** reserve (penalty, not a
  hard floor) so the LP stays feasible. `max_grid_import_kw: 1.54` models the
  **7 A AC input cap** shared by passthrough load + charging.
- **A/C peak management:** `control.ac_off_while_charging: true` switches the
  office A/C (`switch.office_a_c`) **off while the battery is charging**, so it
  doesn't eat the shared 7 A grid input — more cheap energy goes into the
  battery. Zeus restores only an A/C it switched off itself (won't fight a
  manual/overnight off). The A/C plug's power (`sensor.office_a_c_power`) also
  feeds the forecaster.
- **Forecast:** `forecast.model: two_component` — a flat base load plus a
  temperature-driven A/C component, regressed against **Open-Meteo** temperature
  (cooling-degrees over `base_temp_c`). Load + A/C history are persisted on the
  NAS-backed PVC (`load_history.csv` / `ac_history.csv`) so the model keeps more
  than HA's short recorder retention. Event-driven re-plan: `run.poll_seconds:
  120` re-optimizes early when the live load drops ≥ `replan_load_drop_kw`
  (e.g. the A/C cycles off, opening charge headroom under the 7 A cap).
- **Persistence (NAS001 / SMB):** `persistence.storageClassName: smb` puts
  `/app/reports` on the NAS over SMB (via the `csi-driver-smb` platform service),
  so history/reports survive node loss. The share is `//nas001.lab.local/zeus-data`,
  resolved in-cluster via [`coredns-config`](../../platform/coredns-config) (the
  old static IP `.102` went stale after a DHCP change on 2026-06-28). See
  [`platform/csi-driver-smb-config`](../../platform/csi-driver-smb-config).

## Observability

`/metrics` on port 9000 (prometheus_client), scraped via the `ServiceMonitor`.

*State / plan:* `zeus_soc_percent`, `zeus_energy_stored_kwh`,
`zeus_target_charge_kw`, `zeus_target_discharge_kw`, `zeus_plan_cost_eur`,
`zeus_import_price_eur_per_kwh`, `zeus_working_mode{mode=…}`, `zeus_mode_code`
(commanded), `zeus_battery_power_w` + `zeus_actual_mode_code` (**measured** from
the live power flow — ⚠️ derived from the Bluetti's own `grid_input_power`
sensor, which **misreports as passthrough during discharge** (reads ≈
`ac_output_power`), so these two tiles read ~0 / idle even while the battery is
discharging. The **Aeotec** whole-home meter `zeus_grid_power_w` is the source of
truth: low grid import + nonzero load ⇒ the battery is covering it),
`zeus_control_available` (1/0 — the apex300 select goes
404 intermittently), `zeus_next_charge_in_seconds`,
`zeus_next_discharge_in_seconds`, `zeus_last_cycle_timestamp_seconds`,
`zeus_cycle_failures_total`.

*Prices:* `zeus_price_today_eur_per_kwh{hour}`, `_min`/`_max`,
`zeus_price_now_marker_eur_per_kwh{hour}` (current hour, for the live-bar
highlight), `zeus_price_position_pct`.

*Realized savings (today):* `zeus_savings_today_eur`,
`zeus_baseline_cost_today_eur`, `zeus_actual_cost_today_eur`,
`zeus_energy_charged_today_kwh`, `zeus_energy_discharged_today_kwh`,
`zeus_daily_savings_eur{date}` (trailing ~400 days, for the monthly view).

*Forecast / accuracy:* `zeus_forecast_load_kwh` (current slot),
`zeus_realized_load_kwh` (last completed slot — compare with `offset 1h` for
true accuracy), `zeus_load_kwh{ts,kind}` (per-slot load on a wall-clock axis,
`kind=actual|forecast`, `ts`=slot-start epoch-ms, cleared each cycle).

*Predicted savings (forward horizon):* `zeus_predicted_savings_eur` (next ~36 h
vs a no-battery baseline), `zeus_predicted_baseline_cost_eur`,
`zeus_predicted_optimized_cost_eur`, `zeus_horizon_cum_savings_eur{ts}`
(cumulative savings through each future slot, for the next-36 h ramp chart).

**Grafana dashboards** — provisioned as ConfigMap `zeus-dashboard` (the template
globs `dashboards/*.json`), labeled `grafana_dashboard=1`. **Datasource split by
purpose** (see zeus [ADR-0010](../../../zeus/.docs/adr/0010-dashboard-datasource-strategy.md)):
live operational dashboards stay on **Prometheus** (15 s scrape + ops-only
metrics); durable savings/forecast "reports" use **InfluxDB** (uid `influxdb`).

- **`zeus-battery-optimizer`** ("Zeus — Battery Optimizer", **Prometheus**) — full
  operations view (SoC, mode timeline, prices, target power, cost, savings, live
  Aeotec grid power + capacity cross-check). Fixed `now-24h..now`.
- **`zeus-kiosk`** ("Zeus — Live (kiosk)", **Prometheus**) — compact wall display
  (Rackmate T1 1280×400). **Tile-by-tile:** [`.docs/zeus-kiosk-dashboard.md`](../../.docs/zeus-kiosk-dashboard.md).
- **`zeus-monthly-influx`** ("Zeus — Monthly Savings & Mode", rolling
  30 d) — daily savings bars (green ≥0 / red loss), cumulative savings, time-in-mode
  stacked bars, load cost actual-vs-forecast, forecast error (MAE/Total), SoC,
  import price, and grid-power-vs-capacity (blue grid, red dotted running peak,
  yellow dotted **2.5 kW** capaciteitstarief floor, all in kW on one axis).
- **`zeus-forecast-influx`** ("Zeus — Savings Forecast") — predicted
  **next-36 h** savings/baseline/optimized stat cards, savings evolution, and the
  **real future-dated** look-ahead cumulative-savings + per-slot-load curves.

> **Why the live dashboards aren't on InfluxDB:** they read Prometheus-only metrics
> (`zeus_next_charge/discharge_in_seconds`, `zeus_last_cycle_timestamp_seconds`,
> `zeus_cycle_failures_total`, the slot price curve `zeus_price_today_*` /
> `zeus_price_now_marker_*`, `zeus_plan_cost_eur`) and want 15 s granularity — no
> durability gain for a "now" view. See ADR-0010.

> **Plotting the future — InfluxDB vs the old Prometheus hack:** the InfluxDB
> forecast dashboard stores **real future-dated points** (`zeus_forecast` written at
> slot timestamps) and renders forward lines directly (range `now-24h..now+40h`).
> The retired Prometheus `zeus-forecast` couldn't hold future samples, so it used a
> bar-chart with future-ms `ts` labels (data-driven x-axis, not time-clipped) —
> see zeus [ADR-0007](../../../zeus/.docs/adr/0007-forecast-visualization-grafana-prometheus.md),
> now partially superseded by [ADR-0009](../../../zeus/.docs/adr/0009-influxdb-durable-time-series-store.md)/ADR-0010.

**InfluxDB datasource provisioning + Flux gotchas** (datasource registered via a
static ConfigMap mount, series named with `rename()`, per-bar colour via
`barchart`/`colorByField`, constant lines via `array.from`, local dates via the
`timezone` `location` option) are documented in ADR-0010 and the
`platform/observability-config/templates/grafana-influxdb-datasource-configmap.yaml`
comments.

The kube-prometheus-stack Grafana sidecar runs with `NAMESPACE=ALL`, so the
ConfigMap can live in the `zeus` namespace and still be picked up. The sidecar's
immediate reload webhook logs a harmless `403` (`provisioning:reload` perm
missing); Grafana's file provisioner polls the folder and loads it anyway.

## Secrets (SealedSecret)

`HA_TOKEN`, `MQTT_USER`, `MQTT_PASS`, (optional `ENTSOE_TOKEN`) are sealed into
`zeus-secrets` and injected as env; `config.yaml` references them as `${VAR}`.
Seal new values into `.config/<env>/zeus.yaml` under
`secret.sealedSecret.encryptedData`:

```sh
echo -n '<value>' | kubeseal --raw \
  --controller-name sealed-secrets --controller-namespace argocd \
  --namespace zeus --name zeus-secrets --from-file=/dev/stdin
```

The controller is `sealed-secrets` in namespace `argocd`.

## Building & releasing the image (arm64)

Releases go through **GitHub Actions CI** in the source repo (pytest + ruff on
every push/PR; arm64 build & push to Docker Hub on a `v*` tag):

```sh
# in the zeus source repo (github.com/jellebens/zeus)
git tag vX.Y.Z && git push origin vX.Y.Z      # CI builds + pushes jellebens/zeus:X.Y.Z
```
The repo is **private**, so the Actions API is 404 unauthenticated — poll Docker
Hub for readiness: `https://hub.docker.com/v2/repositories/jellebens/zeus/tags/X.Y.Z`.
Then bump `image.tag` in [`values.yaml`](values.yaml), push to `main`, and
`argocd app sync zeus --core`.

Manual fallback (CI down):
```sh
docker buildx build --platform linux/arm64 --provenance=false \
  -t jellebens/zeus:<tag> --push .
```

## MQTT / Home Assistant

Broker (and the HA base URL) is `vesta.local:1883` / `:8123` — `.local`/mDNS
names don't resolve through CoreDNS by default, so they're made resolvable
in-cluster by the `vesta.local` forward in
[`coredns-config`](../../platform/coredns-config) (→ router `.1` → `.18`).
(`core-mosquitto` only resolves inside HA's docker network.) Discovery sensors published under base
topic `zeus`: `sensor.zeus_battery_savings_today`, `_baseline_cost_today`,
`_actual_cost_today`, `_target_charge_power`, `_target_discharge_power`.

## Grid metering — note on the Aeotec ZW095 (not a Zeus input)

Zeus's grid/capacity signal is the **Fluvius digital meter**
(`sensor.fluvius_meter_1sag1100121989_peak_power`), **not** the Aeotec Home
Energy Meter Gen5 (**ZW095**, Z-Wave **node 15**, manufacturer `0x0086`,
product `0x0002:0x005F`). The ZW095 is an independent monitoring device — **Zeus
does not read it, so a ZW095 fault does not affect Zeus.**

Diagnosed 2026-06-27: the ZW095 "stopped updating" in HA. Findings — node is
reachable (`ping` → alive) and still sends **threshold-triggered power reports**,
but its **time-interval reports (param 111) never fire**, so kWh/V/A freeze.
Config writes from the **official Z-Wave JS add-on don't land on the device**
(set param 111 → HA returns 200 but cadence never changes; verified over the WS
API too). The HEM was excluded/re-included before (old node 14 entities
`home_energy_meter_gen5_*` are stale; live ones are `utility_room_home_energy_meter_*`).
Fix is HA-side, not GitOps: **exclude + re-include the unit next to the
controller** (applies lifeline + config cleanly), or run the **Z-Wave JS UI**
add-on (the official one has no associations UI and can't verify config writes).
Association WS commands (`zwave_js/get_associations`) return `unknown_command` on
this HA build.

## Known issues / TODO

- ~~Daily savings can read negative on net-charge days (energy stored but not yet
  discharged, SoC ended high).~~ **Fixed in 0.1.30** — the arbitrage reporter
  marks net banked energy to market (net stored kWh × round-trip η × the day's
  avg price), so charging cheap to use later reads as value, not a loss; it nets
  to zero over a full cycle (`compute_arbitrage_savings(..., credit_stored=True)`).
- **Forecast-accuracy line is a hindcast.** The monthly forecast-vs-actual chart
  recomputes the past forecast with the current model; the MAE/MAPE stat uses
  the true at-the-time series (`zeus_realized_load_kwh` vs
  `zeus_forecast_load_kwh offset 1h`). A frozen at-the-time forecast line would
  need persisting past forecasts.
- **A/C short-cycling:** zeus toggles `switch.office_a_c` only at slot boundaries
  (hourly), so the compressor isn't rapidly cycled. If charging windows ever get
  very fragmented, add a minimum on/off dwell time.
- **Forecaster revisit** scheduled ~2026-09-26 (after ~3 months of history): see
  whether quantile/probabilistic forecasting or day-type clustering beats the
  current mean/cooling-degree model.

_Resolved:_ `zeus_daily_savings_eur` is now wired (monthly dashboard);
`sensor.zeus_optimizer_schedule` moved to `json_attributes_topic`; the apex300
control surface is confirmed writable (`ZeusControlUnavailable` alert covers its
intermittent 404s).

- **0.1.41 (2026-06-28):** zeus survives transient HA/MQTT network blips
  (DNS failure / timeout / connection refused) instead of crash-looping —
  `HAClient._get/_post` wrap `requests.RequestException` as `HAError` (so
  `get_float` degrades to its default), and the inter-cycle wait
  (`_sleep_until_next_cycle`) is guarded in the main loop. Triggered by an mDNS
  outage where `vesta.local` briefly stopped resolving and crash-looped the pod
  64×/8 h before the fix.
