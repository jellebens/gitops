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
- **Optimizer:** 36 h horizon, 60 min slots. `cycle_penalty: 0.03` €/kWh of
  throughput (LFP wear) so zeus only cycles when the price spread clearly beats
  wear + losses. `backup_reserve_pct: 30` — a **soft** reserve (penalty, not a
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
  so history/reports survive node loss. See
  [`platform/csi-driver-smb-config`](../../platform/csi-driver-smb-config).

## Observability

`/metrics` on port 9000 (prometheus_client), scraped via the `ServiceMonitor`.

*State / plan:* `zeus_soc_percent`, `zeus_energy_stored_kwh`,
`zeus_target_charge_kw`, `zeus_target_discharge_kw`, `zeus_plan_cost_eur`,
`zeus_import_price_eur_per_kwh`, `zeus_working_mode{mode=…}`, `zeus_mode_code`
(commanded), `zeus_battery_power_w` + `zeus_actual_mode_code` (**measured** from
the live power flow), `zeus_control_available` (1/0 — the apex300 select goes
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
globs `dashboards/*.json`), labeled `grafana_dashboard=1`:
- **`zeus-battery-optimizer`** ("Zeus — Battery Optimizer") — full operations
  view (SoC, mode timeline, prices, target power, cost, savings). Time picker
  hidden (fixed `now-24h..now`).
- **`zeus-kiosk`** ("Zeus — Live (kiosk)") — compact wall display (Rackmate T1
  1280×400). **Tile-by-tile:** [`.docs/zeus-kiosk-dashboard.md`](../../.docs/zeus-kiosk-dashboard.md).
- **`zeus-monthly`** ("Zeus — Monthly …", rolling 30 d, picker visible) — daily
  savings bars (green ≥0 / red loss), cumulative savings, time-in-mode stacked
  bars, plus daily forecast **cost & error in €** (MAE/Total/MAPE over the
  selected range — for historical accuracy review).
- **`zeus-forecast`** ("Zeus — Savings Forecast", picker visible) — predicted
  **next-36 h savings** (€) with baseline/optimized breakdown, an
  evolution-over-time chart, and a cumulative-savings bar chart spanning the
  next 36 h (red below 0 / green above 0).

> **Plotting the future in Grafana + Prometheus:** Prometheus can't hold
> future-dated samples, and Grafana evaluates instant queries at the range's
> `to` and clips a timeseries x-axis to `[from, to]`. So a forward (now→+36 h)
> *line* can't render — set `to=now+36h` and the instant query reads the future
> (no data). The workaround used here: publish per-slot values with future-ms
> `ts` labels and render with a **bar chart** (its x-axis is data-driven, not
> time-clipped) while the range stays at `to=now` so the query reads fresh.

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

Broker is `vesta.local:1883` (reachable from the cluster; `core-mosquitto` only
resolves inside HA's docker network). Discovery sensors published under base
topic `zeus`: `sensor.zeus_battery_savings_today`, `_baseline_cost_today`,
`_actual_cost_today`, `_target_charge_power`, `_target_discharge_power`.

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
