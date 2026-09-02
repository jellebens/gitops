# Battery — Live (kiosk) dashboard

A compact, glanceable Grafana dashboard for the battery optimizer, sized for
the **Rackmate T1 GeeekPi 1280×400 TFT** (ultra-wide, ~13 grid rows tall, no
scroll). It answers "what is the battery doing **right now**, how did today go,
and is the service healthy?"

- **Grafana UID:** `zeus-kiosk` (unchanged by the JUPITER rebrand) — title "Battery — Live (kiosk)".
  The UID is kept so old links keep resolving; the metrics behind the tiles are
  now the **jupiter** series (see below), not the retired `zeus_*` ones.
- **Kiosk start URL (what the TFT should open):** the **playlist** URL, not the
  bare dashboard — see [Kiosk self-recovery](#kiosk-self-recovery-playlist--freeze-detector):
  `https://grafana.lab.local/playlists/play/<PLAYLIST_UID>?kiosk`
- **Open the dashboard directly (no chrome):**
  `https://grafana.lab.local/d/zeus-kiosk/battery-live-kiosk?kiosk`
  (the slug after the UID is cosmetic — Grafana resolves by UID, so old links keep working)
- **Data source:** Prometheus. Since #245 the tiles read the **jupiter** metrics —
  `jupiter_lar_*` (the live controller: SoC, mode, target, cycle freshness) and
  `jupiter_reporting_*` / `jupiter_savings_*` (reporting service: stored energy,
  price position, today's savings/energy). The old `zeus_*` series are retired
  (zeus decommissioned 2026-07-30, #169). The dashboard auto-refreshes its
  **data** every ~30 s (the kiosk view runs `refresh=5s`); note this is an
  in-place data refresh, **not** a page reload — see below.
- **Source of truth:** [`landingzones/zeus/dashboards/battery-kiosk.json`](../landingzones/zeus/dashboards/battery-kiosk.json)
  (embedded verbatim into the `zeus-dashboard` ConfigMap by
  `landingzones/zeus/templates/dashboard.yaml`, picked up by the
  kube-prometheus-stack Grafana dashboard sidecar). Edits made in the Grafana UI
  are **not** persisted — change the JSON and let Argo CD sync it.

All queries are wrapped in `max(...)` so that during a rolling pod restart (when
the old and new pod both export metrics for a few minutes) each tile still shows
a single value instead of doubling.

## Layout

```
┌────────┬───────┬───────┬───────┬──────────────┬──────────┐  row 1
│        │  SoC  │ Mode  │Stored │ Cheap→Expens │Component │  badge + live state
│  ⚡ Zeus├───────┼───────┼───────┼──────────────┤  health  │
│  badge │Savings│Charged│Dischrg│  Target ±kW  │ (8 rows +│  today + health
│        │       │       │       │  Last cycle  │  clock)  │
└────────┴───────┴───────┴───────┴──────────────┴──────────┘
 x=0     x=4     x=8     x=12    x=16           x=20  (24 wide)
```

The top-left tile is the Zeus avatar badge (a transparent text panel; the
image is embedded as a base64 PNG so no external hosting is needed).

The far-right **x=20** column (4 wide, full height) was freed by #245 (which
removed the dead **Next** and **Fails** tiles), got the **Last refreshed**
clock in #253, was upgraded to the **Component health** grid in #266
(same panel id 15, same footprint — the clock lives on as the grid's
**Grafana** row), and was split by #268 into two side-by-side panels inside
that same footprint (names id 15 at x=20 w=2, statuses id 16 at x=22 w=2).
The middle-left tiles were **not** moved — the no-reflow rule was honoured;
only that column's content changed.

## Row 1 — live state (what it's doing now)

| Tile | Means | Metric | Colors |
|------|-------|--------|--------|
| **SoC** | Battery state of charge (%). | `jupiter_lar_soc_pct` | red < 20%, orange < 50%, green ≥ 50% |
| **Mode** | The working mode currently driven on the battery. | `jupiter_lar_actual_mode` (0/1/2) | **IDLE** purple, **CHARGING** blue, **DISCHARGING** green (filled background) |
| **Stored** | Energy currently in the battery (kWh) = SoC × usable capacity (~13 kWh). More tangible than the bare %. | `jupiter_reporting_energy_stored_kwh` | blue |
| **Cheap→Expensive** | Where the **current** price sits within today's price range: 0 % = cheapest hour, 100 % = most expensive. "Is now a good time to use power?" | `jupiter_reporting_price_position_pct` | green < 40, yellow < 75, red ≥ 75 (filled background) |

## Row 2 — today's totals + health

| Tile | Means | Metric | Colors |
|------|-------|--------|--------|
| **Savings today** | Realized arbitrage savings since local midnight (discharge value − charge cost). Can read slightly negative early in the day if more was charged than discharged so far. | `jupiter_savings_today_eur` | red < €0, green ≥ €0 |
| **Charged** | Energy charged into the battery today (kWh). | `jupiter_savings_charged_today_kwh` | blue |
| **Discharged** | Energy discharged from the battery today (kWh). | `jupiter_savings_discharged_today_kwh` | green |
| **Target ±kW** | The current-slot power setpoint as a single signed number: **positive = charging**, **negative = discharging**, 0 = idle/passthrough. | `jupiter_lar_target_charge_kw − jupiter_lar_target_discharge_kw` | blue > 0, green < 0 |
| **Last cycle** | Time since the last completed optimizer cycle — a **freshness/health** signal. Healthy value is well under ~75 min. | `time() − jupiter_lar_last_cycle_timestamp_seconds` | green, orange > 75 min, red > 2 h |

## Full-column tile — Component health (freeze detector included)

Since #268 this is **two stat panels side by side** in the same x=20 w=4 h=10
footprint (one panel in #266): **id 15 "Component"** (x=20 w=2) is the *name
column* — component names on a normal, uncolored background — and **id 16
"health"** (x=22 w=2) is the *status column*, which alone carries the health
coloring: **GREEN background + white letters = OK, RED = down/stale.** Their
side-by-side titles read "Component | health". Both panels run the **same 8
targets in the same refId order (A–H)** so row *i* of the name column lines
up with row *i* of the status column — keep the two target lists identical
and deterministic, and keep **both** panels titled (equal header heights) or
the rows drift vertically. Text is pinned at 12 px in both panels: stat
shares one auto-computed font size across all its cells, so without the pin
the long `dateTimeFromNow` string in the Grafana row shrinks every OK/DOWN
chip with it (verified by rendering the JSON in a throwaway local Grafana
12.4.2); at 12 px "a few seconds ago" wraps to two lines and fits the w=2
cell. Each boolean row's PromQL is written to return exactly `1` (OK) or `0`
(DOWN), and every row is wrapped in `or on() vector(0)` so a **vanished
series fails RED** ("no data" can never render as green). All exprs were
verified against the live Prometheus before shipping (#266, re-verified
read-only for #268 after the split).

| Row | OK means | Backing PromQL (OK condition) |
|-----|----------|-------------------------------|
| **mqtt** | ≥ 1 EMQX broker node running (same series as mission-control's "EMQX nodes up"). | `(max(emqx_cluster_nodes_running{namespace="mqtt"}) >= bool 1) or on() vector(0)` |
| **HA** | Home Assistant answering the live lar's reads: **zero SoC read errors in 30 m** AND the jupiter-cell scrape is up. Deliberately **not** `jupiter_lar_ha_read_ok` — that gauge is 1 only when *every* read in the last cycle succeeded and routine flaky `ac` reads keep it ~always 0 (verified: 24 h avg = 0 while the system is healthy). The SoC read runs every 15-min cycle, so a truly unreachable HA turns this red within ~2 cycles. | `(((sum(increase(jupiter_lar_ha_read_errors_total{read="soc",namespace="jupiter-tervuren"}[30m])) or on() vector(0)) == bool 0) * on() min(up{job="jupiter-cell",namespace="jupiter-tervuren"})) or on() vector(0)` |
| **Nordpool** | Day-ahead feed healthy: price cache age **< 26 h** (93600 s — the `JupiterPriceFeedDegraded` threshold; a healthy cache-first steady state can go ~23 h between real fetches), **no** retry cooldown, and the price-service scrape up. | `((max(jupiter_price_cache_age_seconds{namespace="jupiter-central"}) < bool 93600) * (max(jupiter_price_cooldown_active{namespace="jupiter-central"}) == bool 0) * min(up{job="price-service",namespace="jupiter-central"})) or on() vector(0)` |
| **Grafana** | The #253 **freeze detector**, restyled by #268: **AMBER background** (it is an *age* indicator — neither green-healthy nor red-down) whose value is the **relative age of the last re-render** (`dateTimeFromNow` on epoch-ms → "a few seconds ago"), re-queried each ~30 s refresh. The rendered string only advances when the tab re-renders, so it stops updating in a frozen tab. **Caveat (accepted with #268):** unlike the pre-#268 absolute clock, a frozen "a few seconds ago" still *reads* healthy at a glance — the playlist/device full reload below stays the real recovery. | `time() * 1000` (`time()` is seconds; `dateTime*` units expect epoch-millis, hence `*1000`) |
| **forecast** | forecast-service scrape up (mirrors `JupiterForecastServiceDown`). | `min(up{job="forecast-service",namespace="jupiter-central"}) or on() vector(0)` |
| **bluetti** | The HA Bluetti integration is alive: the lar's telemetry-staleness verdict is clean. Since lar v0.18.4 (#259) that verdict reads the HA liveness entity `binary_sensor.bluetti_integration_alive` (see `docs/incidents/2026-08-31-bluetti-staleness-deadlock.md`), so this row is the kiosk view of exactly that incident's failure mode. | `(max(jupiter_lar_battery_telemetry_stale{namespace="jupiter-tervuren"}) == bool 0) or on() vector(0)` |
| **lar cell** | The live controller's heartbeat: last completed optimizer cycle **< 35 min** old (2 × the 15-min cycle interval + grace). | `((time() - max(jupiter_lar_last_cycle_timestamp_seconds{namespace="jupiter-tervuren"})) < bool 2100) or on() vector(0)` |
| **reporting** | reporting-service scrape up (feeds the Savings/Stored/price-position tiles). | `min(up{job="reporting-service",namespace="jupiter-central"}) or on() vector(0)` |

Not included: **InfluxDB** — this kiosk's panels are 100 % Prometheus-backed
(verified: every target's datasource type is `prometheus`), so an Influx row
would report on something the kiosk doesn't depend on.

## Prices

The kiosk keeps the **Cheap→Expensive** tile for an at-a-glance "is now a cheap
hour?" read. The full hourly day-ahead price bar chart was removed from the
kiosk to save space. (The full battery dashboard still shows an import-price
time series.)

## Kiosk self-recovery (playlist + freeze detector)

**Background (incident 2026-08-27):** the live kiosk froze while data and the
integration were fine. Root cause: the Grafana **backend was healthy** (pod up,
`/api/health` 200) — the freeze is the **kiosk browser** (Rackmate T1 Chromium
tab) whose long-running tab only ever does an **in-place data refresh** every
~30 s and **never a full page reload**, so it leaks/hangs over days; that day's
#245 ConfigMap redeploy likely tipped an already-degraded tab. It is **not** the
data-refresh rate.

Two independent mitigations (owner's choice, Option 3):

### 1. Freshness tile (shipped, GitOps — now the Component health "Grafana" row)

Originally the #253 `Last refreshed` wall-clock, since #266 the **Grafana**
row of the Component health grid, and since #268 an **amber relative-age**
cell (`dateTimeFromNow` → "a few seconds ago") instead of the absolute clock.
The mechanism is unchanged: the value is re-queried and re-rendered each
~30 s refresh, and in a frozen tab the string stops updating — the other
health rows would sit stale-but-green in a frozen tab. **Trade-off accepted
with #268:** the absolute clock exposed a freeze at a glance (displayed time
vs. your watch); a frozen "a few seconds ago" still *reads* fresh, so
detection now needs a longer look (the string never changing across visits)
and the playlist/device full reload below is the mitigation that actually
recovers the tab. This row ships in the dashboard JSON, so it survives
redeploys.

### 2. Grafana playlist auto-reload (live Grafana state — recreate below)

A single-item **playlist** containing only the `zeus-kiosk` dashboard, with a
~5–10 min auto-advance. The kiosk opens the **playlist** URL so each rotation
re-navigates the view (which re-fetches the dashboard JSON, picking up
redeploys).

- **Kiosk URL:** `https://grafana.lab.local/playlists/play/<PLAYLIST_UID>?kiosk`
  (fill in `<PLAYLIST_UID>` once the playlist is created).
- **Persistence:** Grafana's DB is on a **PVC** (`kube-prometheus-stack-grafana`,
  10Gi longhorn at `/var/lib/grafana`), so a playlist survives pod restarts.
  Playlists are **not** file-provisionable, hence the recreate steps below.

> **⚠ Empirical caveat — the playlist does NOT clear a browser memory leak.**
> Grafana here is **v12.4.2**, a React SPA (Scenes). A playlist advances via the
> app's client-side router (`locationService.push`), i.e. a **same-document**
> route change — **not** a full page reload. This was verified read-only on the
> live instance: navigating dashboard→dashboard kept the same JS VM
> (`window` marker survived), `beforeunload` never fired, and `performance.now()`
> kept climbing on the original document. So a single-item playlist re-renders
> the scene but **does not clear the Chromium JS heap** — it will not, on its
> own, recover a leaked/frozen tab. It still helps by re-pulling the dashboard
> after a redeploy, and the **Grafana row of the Component health tile still
> stops updating on a freeze** (though since #268 it shows a relative age,
> not a clock — see the caveat above). For a guaranteed heap-clearing
> recovery, add a genuine **full page reload** on the device: either a small **meta-refresh wrapper page** (a
> top-level HTML page that iframes the kiosk URL and carries
> `<meta http-equiv="refresh" content="600">`, so each refresh tears down and
> reloads the whole document), or configure the kiosk's Chromium to reload
> periodically (kiosk-browser auto-reload / a cron'd `F5`). The wrapper/device
> reload is the owner's call.

#### Admin auth (the gotcha)

The default `kube-prometheus-stack-grafana` Secret's `admin-user`/`admin-password`
are **empty** — the chart is pointed at an **existing secret**. Real admin creds
live in the **`grafana-admin`** Secret (ns `observability`), configured in
[`.config/lab/observability.yaml`](../.config/lab/observability.yaml):

```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
```

The SealedSecret source is
[`platform/observability-config/templates/grafana-admin-secret.yaml`](../platform/observability-config/templates/grafana-admin-secret.yaml).
Read the live values with:

```sh
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}'     | base64 -d; echo
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Note `grafana.ini` sets `auth.basic.enabled: false`, so the HTTP API will **not**
accept `-u admin:pass` basic auth. Use the **UI login form** (simplest), or a
**service account token** as a `Bearer` header for scripted creation. Anonymous
access is Viewer-only (that is how the kiosk loads with no login).

#### Create / recreate the playlist

Preferred (UI): sign in as admin → **Dashboards → Playlists → New playlist** →
name it e.g. `zeus-kiosk`, interval `10m`, add the **Battery — Live (kiosk)**
dashboard as the only item → Save. Then read the assigned UID from
**Dashboards → Playlists** (or `GET /api/playlists`) and use it in the kiosk URL.

Scripted (service-account token, `auth.basic` is off so Bearer is required):

```sh
GRAFANA=https://grafana.lab.local
TOKEN=<grafana service-account token, Editor+ role>

# create
curl -sk "$GRAFANA/api/playlists" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"zeus-kiosk","interval":"10m",
       "items":[{"type":"dashboard_by_uid","value":"zeus-kiosk"}]}'
# -> response contains "uid":"<PLAYLIST_UID>"

# verify
curl -sk "$GRAFANA/api/playlists" -H "Authorization: Bearer $TOKEN"
```

Kiosk URL becomes `"$GRAFANA/playlists/play/<PLAYLIST_UID>?kiosk"`.

> The exact item schema key can be `dashboard_by_uid` (value = UID) on this
> Grafana version; if the API rejects it, create via the UI (which always writes
> the correct shape) and read the UID back.

### Owner's manual step

Repoint the TFT device's start URL from the bare dashboard
(`/d/zeus-kiosk/...?kiosk`) to the **playlist** URL
(`/playlists/play/<PLAYLIST_UID>?kiosk`). This is a device change, done on the
kiosk, not in this repo.

## Related

- Deployment, metrics list, and the full history dashboard: [`landingzones/zeus/README.md`](../landingzones/zeus/README.md)
- Application source (jupiter): <https://github.com/jellebens/jupiter>
