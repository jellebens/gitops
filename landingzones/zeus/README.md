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
  pvc.yaml              persists generated savings reports (/app/reports)
  deployment.yaml       the zeus pod (envFrom the secret, mounts config + pvc)
  service.yaml          zeus-metrics ClusterIP :9000
  servicemonitor.yaml   Prometheus scrape (label release=kube-prometheus-stack)
  dashboard.yaml        Grafana dashboard ConfigMap (label grafana_dashboard=1)
dashboards/zeus.json    the Grafana dashboard model (loaded via .Files.Get)
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
- **Optimizer:** 36 h horizon, 60 min slots, small cycle penalty.

## Observability

`/metrics` on port 9000 (prometheus_client), scraped via the `ServiceMonitor`.
Metrics: `zeus_soc_percent`, `zeus_energy_stored_kwh`, `zeus_target_charge_kw`,
`zeus_target_discharge_kw`, `zeus_plan_cost_eur`,
`zeus_import_price_eur_per_kwh`, `zeus_working_mode{mode=…}`, `zeus_mode_code`,
`zeus_price_today_eur_per_kwh{hour=…}`, `zeus_price_today_min_eur_per_kwh`,
`zeus_price_today_max_eur_per_kwh`, `zeus_price_now_marker_eur_per_kwh{hour}`
(current hour only, for highlighting the live bar), `zeus_price_position_pct`,
`zeus_next_charge_in_seconds`, `zeus_next_discharge_in_seconds`,
`zeus_savings_today_eur`, `zeus_baseline_cost_today_eur`,
`zeus_actual_cost_today_eur`, `zeus_energy_charged_today_kwh`,
`zeus_energy_discharged_today_kwh`, `zeus_daily_savings_eur{date=…}`,
`zeus_last_cycle_timestamp_seconds`, `zeus_cycle_failures_total`.

**Grafana dashboards** are provisioned as ConfigMap `zeus-dashboard` (the
template globs `dashboards/*.json`), labeled `grafana_dashboard=1`:
- `zeus-battery-optimizer` ("Zeus — Battery Optimizer") — the full history view.
- `zeus-kiosk` ("Zeus — Live (kiosk)") — a compact small-screen/wall-display
  view (Rackmate T1 1280×400). SoC, working mode, savings, charged/discharged,
  energy stored, price position, target power, next action, freshness, failures,
  and a today's-prices bar chart with the current hour highlighted. **Tile-by-tile
  reference:** [`.docs/zeus-kiosk-dashboard.md`](../../.docs/zeus-kiosk-dashboard.md).

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

```sh
# in the zeus source repo (github.com/jellebens/zeus)
docker buildx build --platform linux/arm64 --provenance=false \
  -t jellebens/zeus:<tag> --push .
```
Then bump `image.tag` in [`values.yaml`](values.yaml) and push to `main`.

## MQTT / Home Assistant

Broker is `vesta.local:1883` (reachable from the cluster; `core-mosquitto` only
resolves inside HA's docker network). Discovery sensors published under base
topic `zeus`: `sensor.zeus_battery_savings_today`, `_baseline_cost_today`,
`_actual_cost_today`, `_target_charge_power`, `_target_discharge_power`.

## Known issues / TODO

- `sensor.zeus_optimizer_schedule` reads `unknown` — the full schedule JSON
  exceeds HA's 255-char state limit. Move the payload to `json_attributes_topic`.
- Daily savings can read negative on net-charge days (energy stored but not yet
  discharged, SoC ended high). Possible fix: credit end-of-day SoC delta at avg
  price.
- `zeus_daily_savings_eur` / `set_daily_savings()` exist in the image but aren't
  wired into the reporter yet.
