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
│        │  SoC  │ Mode  │Stored │ Cheap→Expens │          │  badge + live state
│  ⚡ Zeus├───────┼───────┼───────┼──────────────┤   Last   │
│  badge │Savings│Charged│Dischrg│  Target ±kW  │ refreshed│  today + health
│        │       │       │       │  Last cycle  │  (clock) │
└────────┴───────┴───────┴───────┴──────────────┴──────────┘
 x=0     x=4     x=8     x=12    x=16           x=20  (24 wide)
```

The top-left tile is the Zeus avatar badge (a transparent text panel; the
image is embedded as a base64 PNG so no external hosting is needed).

The far-right **x=20** column (4 wide, full height) was freed by #245 (which
removed the dead **Next** and **Fails** tiles) and now holds the **Last
refreshed** clock (#253). The middle-left tiles were **not** moved — the
no-reflow rule was honoured; only the empty column was filled.

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

## Full-column tile — freeze detector

| Tile | Means | Metric | Notes |
|------|-------|--------|-------|
| **Last refreshed** | Wall-clock of the **last successful data refresh** (a stat panel, `dateTimeAsLocal` unit). Re-evaluated on every ~30 s refresh, so on a healthy kiosk it tracks real time; when the browser tab freezes the clock **stops advancing** = an at-a-glance freeze detector. | `time() * 1000` | Prometheus `time()` is in **seconds**; the `dateTime*` units expect **epoch-millis**, so the query multiplies by 1000. Without the `*1000` the tile renders 1970. Verified via `/api/ds/query`: the expr returns a 13-digit epoch-ms matching wall-clock. |

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

### 1. "Last refreshed" timestamp tile (shipped, GitOps)

The `Last refreshed` clock (above) makes any freeze **visible**: a stale clock
on the TFT = the tab is stuck, regardless of anything else. This is the reliable
detector and ships in the dashboard JSON, so it survives redeploys.

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
> after a redeploy, and the **Last refreshed tile exposes the freeze either
> way.** For a guaranteed heap-clearing recovery, add a genuine **full page
> reload** on the device: either a small **meta-refresh wrapper page** (a
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
