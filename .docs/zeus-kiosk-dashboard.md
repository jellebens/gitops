# Zeus — Live (kiosk) dashboard

A compact, glanceable Grafana dashboard for the Zeus battery optimizer, sized for
the **Rackmate T1 GeeekPi 1280×400 TFT** (ultra-wide, ~13 grid rows tall, no
scroll). It answers "what is the battery doing **right now**, how did today go,
and is the service healthy?"

- **Grafana UID:** `zeus-kiosk` — title "Zeus — Live (kiosk)"
- **Open full-screen (no chrome):** `http://<grafana>/d/zeus-kiosk/zeus-live-kiosk?kiosk`
- **Data source:** Prometheus (`zeus_*` metrics scraped from the zeus pod every
  60 s via the `ServiceMonitor`). The dashboard auto-refreshes every 30 s.
- **Source of truth:** [`landingzones/zeus/dashboards/zeus-kiosk.json`](../landingzones/zeus/dashboards/zeus-kiosk.json).
  Edits made in the Grafana UI are **not** persisted — change the JSON and let
  Argo CD sync it.

All queries are wrapped in `max(...)` so that during a rolling pod restart (when
the old and new pod both export metrics for a few minutes) each tile still shows
a single value instead of doubling.

## Layout

```
┌────────┬────────┬────────┬──────────────┬───────────┐  row 1 — live state
│  SoC   │  Mode  │ Stored │ Cheap→Expens │   Next    │
├────────┼────────┼────────┼──────────────┼───────────┤  row 2 — today + health
│ Savings│Charged │Dischrg │ Target ±kW   │ Last cycle│ Fails │
├────────┴────────┴────────┴──────────────┴───────────┴───────┤
│   Today €/kWh by hour  (00:00 … 23:00, colored bands)        │  price chart
└─────────────────────────────────────────────────────────────┘
```

## Row 1 — live state (what it's doing now)

| Tile | Means | Metric | Colors |
|------|-------|--------|--------|
| **SoC** | Battery state of charge (%). | `zeus_soc_percent` | red < 20%, orange < 50%, green ≥ 50% |
| **Mode** | The working mode Zeus is currently driving on the battery. | `zeus_mode_code` (0/1/2) | **IDLE** purple, **CHARGING** blue, **DISCHARGING** green (filled background) |
| **Stored** | Energy currently in the battery (kWh) = SoC × usable capacity (~13 kWh). More tangible than the bare %. | `zeus_energy_stored_kwh` | blue |
| **Cheap→Expensive** | Where the **current** price sits within today's price range: 0 % = the cheapest hour of the day, 100 % = the most expensive. A quick "is now a good time to use power?" gauge. | `zeus_price_position_pct` | green < 40, yellow < 75, red ≥ 75 (filled background) |
| **Next** | Time until the next scheduled **chg** (charge) and **dis** (discharge) slot in the optimizer plan. `none` = nothing of that kind scheduled in the horizon. | `zeus_next_charge_in_seconds`, `zeus_next_discharge_in_seconds` | neutral |

## Row 2 — today's totals + health

| Tile | Means | Metric | Colors |
|------|-------|--------|--------|
| **Savings today** | Realized arbitrage savings since local midnight (discharge value − charge cost). Can read slightly negative early in the day if more was charged than discharged so far. | `zeus_savings_today_eur` | red < €0, green ≥ €0 |
| **Charged** | Energy charged into the battery today (kWh). | `zeus_energy_charged_today_kwh` | blue |
| **Discharged** | Energy discharged from the battery today (kWh). | `zeus_energy_discharged_today_kwh` | green |
| **Target ±kW** | The current-slot power setpoint as a single signed number: **positive = charging**, **negative = discharging**, 0 = idle/passthrough. | `zeus_target_charge_kw − zeus_target_discharge_kw` | blue > 0, green < 0 |
| **Last cycle** | Time since the last completed optimizer cycle — a **freshness/health** signal. Cycles run hourly, so a healthy value is well under 1 h. | `time() − zeus_last_cycle_timestamp_seconds` | green, orange > 75 min, red > 2 h |
| **Fails** | Count of optimizer cycles that raised an error since the pod started. Should be 0. | `zeus_cycle_failures_total` | green at 0, red ≥ 1 |

## Price chart — "Today €/kWh by hour"

The full day-ahead import price curve, one bar per hour.

- **X-axis:** hour of the day, formatted `00:00 … 23:00` (Europe/Brussels local
  time). Built from `zeus_price_today_eur_per_kwh{hour}`; the `:00` suffix is
  added in the query with `label_replace`.
- **Y-axis / value:** all-in import price in €/kWh.
- **Bar colors (relative to today's own min/max range):**
  - 🟢 **green** — bottom 20 % of the range (the cheapest hours)
  - 🟠 **orange** — the middle 60 %
  - 🔴 **red** — top 20 % of the range (the most expensive hours)
  - 🔵 **blue** — the **current hour** ("you are here")

  Bands use Grafana *percentage-mode thresholds*, so they recompute every day
  from that day's cheapest/most-expensive prices — no fixed €/kWh cutoffs.

> Note: bands are by **price range**, not by count. If one hour is far cheaper
> than the rest, only that hour may be green. To band by *rank* instead
> (e.g. always the cheapest ~5 hours), Zeus would need to export quantile
> thresholds as metrics.

### How "now" is highlighted without a gap or extra bar
The chart stacks two mutually-exclusive series so every hour is a single
full-width bar:
- curve: `... zeus_price_today_eur_per_kwh unless on(hour) zeus_price_now_marker_eur_per_kwh`
  (all hours **except** the current one), colored by the green/orange/red bands;
- marker: `zeus_price_now_marker_eur_per_kwh` (the current hour only), forced blue.

## Related

- Deployment, metrics list, and the full history dashboard: [`landingzones/zeus/README.md`](../landingzones/zeus/README.md)
- Application source: <https://github.com/jellebens/zeus>
