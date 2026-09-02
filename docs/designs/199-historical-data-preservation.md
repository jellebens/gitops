# Design — Historical-data preservation before the zeus decommission (#199)

**Status:** DESIGN / investigation only. No live data migration, no data-moving
manifest changes are made by this card. Every migration/write/delete step
described here is an **owner-scheduled** action, not performed here.

**Owner directive (2026-07-20):** *"make sure to migrate the historical data."*
When #169 decommissions zeus (~2026-08-06) the kiosk history panels and months of
battery history must NOT be lost.

**Scope boundary.** This is the **InfluxDB** side of the kiosk migration. The
**Prometheus / dashboard-query** side (re-pointing panels off `zeus_*` Prometheus
metrics) is #165 / #198. Related: #168 (`site_id` archive backfill), #182
(InfluxDB → Longhorn), #169 (the decommission itself, the deadline).

---

## 0. Premise correction — jupiter DOES write InfluxDB

The #165 migration plan
(`docs/dashboard-zeus-to-jupiter-lar-migration-plan.md`) states, verbatim:

> "jupiter-lar writes nothing to InfluxDB … no lar InfluxDB writer at all"
> — GAP on every `zeus_state`-backed panel.

That is true **only of the LAR** (the actuation service on the battery). It is
**false for jupiter as a whole**. The central **reporting-service** and
**forecast-service** both write InfluxDB today, site-tagged (`site_id=tervuren`),
byte-parity with zeus's line format. The #165 doc conflated "the lar" with "the
fleet" and therefore over-counted the gap. This card re-establishes the real
coverage.

### What jupiter actually writes (source of truth: the code)

All writes go to the **one shared InfluxDB 2.x bucket `zeus`** (org `zeus`),
tagged `site_id` via `jupiter_shared.influx.site_line` (ADR-0019 / D5). The line
builder is **byte-for-byte `zeus.influx.line`**, so a jupiter point with the same
measurement + tag set + field + timestamp *overwrites* the equivalent zeus point
rather than duplicating — but note the jupiter measurements are **new names**
(`jupiter_*`), so in practice they sit **alongside** the `zeus_*` series, not on
top of them.

| Measurement | Fields written | Tags | Writer | Source file |
|---|---|---|---|---|
| `jupiter_state` | `soc_pct`, `energy_stored_kwh`, `mode_code`, `import_price_eur_per_kwh`, `price_position_pct`, `savings_today_eur` | `site_id` | reporting-service (per refresh) | `services/reporting/jupiter_reporting/realized.py` `build_state_lines()` |
| `jupiter_daily_savings` | `eur` (keyed at local midnight, overwrites same-day) | `site_id` | reporting-service | same |
| `jupiter_forecast` | `load_kwh` (per **HOUR** — not per-15-min slot) | `site_id`, `target` | forecast-service (per trainer run) | `services/forecast/jupiter_forecast/forecast_influx.py` |
| `jupiter_forecast_frozen` | `load_kwh` (first `frozen_hours` = 6, write-once) | `site_id`, `target` | forecast-service | same |

**Fields that `build_state_lines` *could* emit but does NOT populate today**
(the snapshot leaves them `None`, so they are omitted from the line): `grid_power_w`
(dropped in #170 — the lar doesn't sense whole-home grid power), and
`predicted_savings_eur`. Treat these as **not written**.

**First sample / "since when":** the `jupiter_*` series exist only from when the
reporting/forecast services began writing (the D5 tag cutover era,
~2026-07-04 onward). There is **no** jupiter-written history before that — the
pre-cutover months exist **only** under `zeus_*`. This is the crux of the
preservation problem: even for series jupiter now writes, the *history* lives
under `zeus_*` and must be retained (Section 3).

### What jupiter READS from InfluxDB (a load-bearing zeus dependency)

The forecast **trainer** reads, but does **not** write, these zeus series
(`services/forecast/jupiter_forecast/history.py`, `train.py`
`LOAD_MEASUREMENT = "zeus_load_history"`):

- `zeus_load_history` field `kwh` — realized critical-load hourly energy (primary
  training target).
- `zeus_load_history` field `ac_kwh` — A/C-plug hourly energy (second target).
- `zeus_state` field `grid_power_w` — whole-home grid-import power, resampled to
  the `whole_home` training target.

**This is the single most important finding of this card.** After zeus scales to
0, **nothing writes `zeus_load_history` or `zeus_state.grid_power_w`**, so the
trainer's ~30-day training window starves and eventually the forecast-service can
only serve its last-trained artifact (age alerting via
`jupiter_forecast_artifact_age_seconds`). This is a **jupiter-continuity** impact
(forecast quality feeds optimization), not merely a cosmetic kiosk loss. See the
gap table (G-row `load_history`) and Section 4.2.

---

## 1. What the kiosk / history panels read from InfluxDB

The four "kiosk" dashboards the migration cares about — `ops-kiosk.json`,
`battery-kiosk.json`, `mission-control.json`, `ops-resources-use.json` — contain
**zero** Flux/InfluxDB history targets. Their `zeus_*` references are all
**Prometheus** metrics (`zeus_soc_percent`, `zeus_cycle_failures_total`,
`zeus_last_cycle_timestamp_seconds`, …) → that is the **#165/#198** scope, not
this card.

The actual InfluxDB (Flux `from(bucket:"zeus")`) history panels live in these 8
dashboards under `landingzones/zeus/dashboards/`:
`gitops-data-health.json`, `forecast-history.json`, `savings-economics.json`,
`battery-monthly.json`, `consumption-analysis.json`, `forecast-accuracy.json`,
`home-energy-ha.json`, `price-grid.json`.

Every distinct `(_measurement, _field)` they read (occurrence counts across the 8
files):

| Measurement.field | Family | Occurrences |
|---|---|---:|
| `zeus_load_history.kwh` | live wide-era | 14 |
| `zeus_forecast_frozen.load_kwh` | live | 11 |
| `zeus_state.import_price_eur` | live wide | 9 |
| `zeus_import_price_eur_per_kwh.value` | frozen archive | 8 |
| `zeus_state.grid_power_w` | live wide | 7 |
| `zeus_daily_savings.eur` | live | 7 |
| `zeus_forecast.load_kwh` | live | 6 |
| `zeus_savings.today_eur` | live | 5 |
| `zeus_savings.discharged_today_kwh` | live | 5 |
| `zeus_realized_load_kwh.value` | frozen archive | 5 |
| `zeus_grid_power_w.value` | frozen archive | 5 |
| `zeus_state.mode_code` | live wide | 3 |
| `zeus_state.capacity_peak_kw` | live wide | 3 |
| `zeus_mode_code.value` | frozen archive | 3 |
| `zeus_forecast_load_kwh.value` | frozen archive | 3 |
| `zeus_state.soc_pct` | live wide | 2 |
| `zeus_state.predicted_savings_eur` | live wide | 2 |
| `zeus_savings.charged_today_kwh` | live | 2 |
| `zeus_predicted_savings_eur.value` | frozen archive | 2 |
| `zeus_capacity_peak_kw.value` | frozen archive | 2 |
| `zeus_state.predicted_optimized_eur` | live wide | 1 |
| `zeus_state.predicted_baseline_eur` | live wide | 1 |
| `zeus_soc_percent.value` | frozen archive | 1 |
| `zeus_savings.baseline_eur` | live | 1 |
| `zeus_savings.actual_eur` | live | 1 |
| `zeus_predicted_optimized_cost_eur.value` | frozen archive | 1 |
| `zeus_predicted_baseline_cost_eur.value` | frozen archive | 1 |
| `zeus_load_history.ac_kwh` | live | 1 |
| `zeus_forecast.cum_savings_eur` | live | 1 |

Plus one **HA-recorder** path (out of scope for the zeus bucket): `home-energy-ha.json`
reads `entity_id="zeus_battery_savings_today"` `.value` from the **`homeassistant`**
bucket. That is HA's own InfluxDB integration, unaffected by the zeus
decommission; only relevant if HA's own recorder config changes (hestia).

**Two families.** Per #168's read-only survey, the single-field standalone
measurements (`zeus_soc_percent`, `zeus_grid_power_w`, `zeus_mode_code`,
`zeus_import_price_eur_per_kwh`, `zeus_realized_load_kwh`, `zeus_forecast_load_kwh`,
`zeus_predicted_*`, `zeus_capacity_peak_kw`) are a **frozen archive** — zeus
stopped writing them at **2026-06-28T18:38:57Z** when it refactored to the wide
`zeus_state`/`zeus_savings` points. Panels reading those are **already** reading
only historical data; the decommission changes nothing for them. Their survival
depends solely on the bucket not being deleted (Section 3).

---

## 2. Per-series gap table (kiosk-history series → post-#169 source)

Legend: **✅ covered** = jupiter writes an equivalent going forward;
**⚠ mapped-with-caveat** = covered but the panel query must change (measurement or
field rename, or a unit/shape change); **❌ gap** = no jupiter equivalent, series
only ever exists under `zeus_*`. In every "covered" row the **pre-cutover
history** still lives only under `zeus_*` and needs the archive retained/queried
(Section 3) — coverage is about *going-forward writes*, not history.

| Kiosk-history series (`zeus_*`) | Post-#169 going-forward source | Status | Note |
|---|---|---|---|
| `zeus_state.soc_pct` | `jupiter_state.soc_pct` | ✅ | measurement rename only |
| `zeus_state.mode_code` | `jupiter_state.mode_code` | ✅ | measurement rename |
| `zeus_state.import_price_eur` | `jupiter_state.import_price_eur_per_kwh` | ⚠ | **field rename** (`import_price_eur` → `import_price_eur_per_kwh`) |
| `zeus_savings.today_eur` | `jupiter_state.savings_today_eur` | ⚠ | moved from `zeus_savings` measurement into `jupiter_state` |
| `zeus_daily_savings.eur` | `jupiter_daily_savings.eur` | ✅ | measurement rename |
| `zeus_forecast.load_kwh` | `jupiter_forecast.load_kwh` | ⚠ | **shape change**: jupiter is per-HOUR; zeus panels multiply per-slot by 4 → drop the `* 4` |
| `zeus_forecast_frozen.load_kwh` | `jupiter_forecast_frozen.load_kwh` | ⚠ | same per-hour vs per-slot shape change |
| `zeus_load_history.kwh` | — | ❌ **GAP** | trainer *reads* this; nothing writes it after zeus. **Critical** (Section 4.2) |
| `zeus_load_history.ac_kwh` | — | ❌ **GAP** | same |
| `zeus_state.grid_power_w` | — | ❌ GAP | dropped in #170 (lar doesn't sense whole-home grid power) |
| `zeus_state.capacity_peak_kw` | — | ❌ GAP | not in jupiter_state |
| `zeus_state.predicted_savings_eur` | — | ❌ GAP | field exists in builder but never populated |
| `zeus_state.predicted_optimized_eur` | — | ❌ GAP | not written |
| `zeus_state.predicted_baseline_eur` | — | ❌ GAP | not written |
| `zeus_savings.charged_today_kwh` | — | ❌ GAP | jupiter writes only `savings_today_eur`, not the energy/cost breakdown |
| `zeus_savings.discharged_today_kwh` | — | ❌ GAP | same |
| `zeus_savings.baseline_eur` | — | ❌ GAP | same |
| `zeus_savings.actual_eur` | — | ❌ GAP | same |
| `zeus_forecast.cum_savings_eur` | — | ❌ GAP | `jupiter_forecast` carries only `load_kwh` |
| `zeus_soc_percent.value` (archive) | `jupiter_state.soc_pct` (live) | ⚠ | frozen since 2026-06-28; history-only, archive-retain |
| `zeus_mode_code.value` (archive) | `jupiter_state.mode_code` (live) | ⚠ | frozen archive |
| `zeus_import_price_eur_per_kwh.value` (archive) | `jupiter_state.import_price_eur_per_kwh` (live) | ⚠ | frozen archive |
| `zeus_forecast_load_kwh.value` (archive) | `jupiter_forecast.load_kwh` (live) | ⚠ | frozen archive; shape caveat |
| `zeus_grid_power_w.value` (archive) | — | ❌ GAP | frozen archive; no live jupiter equivalent |
| `zeus_realized_load_kwh.value` (archive) | — | ❌ GAP | frozen archive |
| `zeus_predicted_savings_eur.value` (archive) | — | ❌ GAP | frozen archive |
| `zeus_predicted_optimized_cost_eur.value` (archive) | — | ❌ GAP | frozen archive |
| `zeus_predicted_baseline_cost_eur.value` (archive) | — | ❌ GAP | frozen archive |
| `zeus_capacity_peak_kw.value` (archive) | — | ❌ GAP | frozen archive |

**Summary:** the *core kiosk story* (SoC, mode, import price, daily & today
savings, load forecast + frozen forecast) is **covered going forward** by
`jupiter_state` / `jupiter_daily_savings` / `jupiter_forecast*`, subgroups needing
a field/shape tweak in the panel query (the #165/#198 dashboard work). The **true
going-forward gaps** are: the forecast **training inputs** (`zeus_load_history`
kwh/ac_kwh + `zeus_state.grid_power_w`), the **savings breakdown**
(`charged/discharged/baseline/actual`), the **predicted-cost / capacity** fields,
and `zeus_forecast.cum_savings_eur`. Everything in the "frozen archive" family is
history-only and simply needs the bucket retained.

---

## 3. Preserving the existing zeus archive

**Retention is INFINITE.** Per both #168's `RUNBOOK-site-id-backfill.md` and
#182's `RUNBOOK-longhorn-migration.md`, the `zeus` bucket has **infinite
retention** (as does `homeassistant`). Consequences:

- **Scaling zeus to 0 does NOT age out or delete any data.** Points already in the
  bucket live forever unless *explicitly* deleted (`influx delete`, dropping a
  measurement) or the underlying volume/PVC is destroyed. The decommission's
  "retire `zeus_*`" wording must NOT be read as "delete the `zeus_*` data."
- **"Let it age out" is not an option and is not needed** — there is no retention
  clock to wait on.

**The data is backed up.** `platform/influxdb-config` runs a nightly full
`influx backup` (03:30, 14-day retain) **plus** hourly incremental CSV export
(3-day retain) for buckets **`zeus`** and `homeassistant`, to the
`influxdb-backups` PVC on the SMB NAS (DS918). So even a bucket loss is
recoverable from the NAS within the backup-retention window — but the backup
retention (14 d full) is **shorter than "forever,"** so backups are a
disaster-recovery net, not the archive of record. The archive of record is the
live bucket.

**Longhorn move (#182) is orthogonal but relevant.** #182 migrates the InfluxDB
PVC off node-pinned `local-path` (reclaim policy `Delete` — deleting the PVC
deletes the data) onto `longhorn` (3 replicas, survives a node loss). Until #182
lands, the zeus archive sits on a single node's disk with a `Delete` reclaim
policy — a second reason to treat the PVC as precious and to prefer running #182
**before** the decommission window if scheduling allows.

**Site-tag backfill (#168) is recommended but not required for preservation.** The
frozen-archive measurements are untagged; #168 re-tags them `site_id=tervuren`
(additive, never deletes the untagged originals). Nothing is *lost* without #168 —
untagged points remain queryable — but running #168 before decommission lets the
history panels use a single `site_id`-filtered query across both eras and lets the
trainer retire its `include_untagged` flag.

---

## 4. Preservation plan (owner-scheduled steps; nothing executed here)

### 4.1 Retain the bucket — the non-negotiable

1. Decommission = **scale the zeus Deployment/pod to 0 only.** Do **not**
   `influx delete`, do **not** drop any `zeus_*` measurement, do **not** delete
   the `influxdb-influxdb2` PVC. Infinite retention means scale-to-0 preserves
   everything indefinitely.
2. Before the window, confirm the latest `influxdb-backup-*` job is `Completed`
   (or trigger one) so a fresh full NAS backup of the `zeus` bucket exists as the
   DR net.
3. Prefer to land **#182 (Longhorn)** before decommission so the archive is on
   redundant storage with no `Delete`-reclaim foot-gun. If #182 has not landed,
   at minimum flip the local-path PV to `Retain` per #182's runbook so a stray
   PVC delete cannot take the data.

### 4.2 Close the one continuity gap that has live-adjacent impact — `zeus_load_history`

The forecast trainer's inputs (`zeus_load_history.kwh` / `.ac_kwh`,
`zeus_state.grid_power_w`) are the only gap that degrades a *live-adjacent*
capability (forecast → optimization quality), not just a history panel. Options,
in preference order:

- **A (recommended): extend a jupiter writer to emit `jupiter_load_history`.** The
  reporting-service already resolves the lar's realized SoC/energy per refresh;
  add an hourly realized-load rollup that writes `jupiter_load_history` with
  fields `kwh` (+ `ac_kwh` if an A/C-plug signal is available), site-tagged, byte-
  parity schema. Then point the trainer's `LOAD_MEASUREMENT` at `jupiter_load_history`
  (or union both during transition). This is a **jupiter-repo** change (out of
  this card's gitops scope) — file it as a jupiter card, gated to land **before**
  the ~30-day training window rolls entirely past zeus's last write.
- **B: source the whole-home grid-power target from HA** instead of
  `zeus_state.grid_power_w` (hestia). Only needed if the `whole_home` forecast
  target is to survive; the critical-load target (A) is the primary one.
- **C (fallback, no code): keep the trainer reading the retained `zeus_load_history`
  archive.** With the bucket retained, the trainer keeps training on a *frozen*
  history that stops advancing at decommission — acceptable only as a short bridge,
  since the window ages out in ~30 days and forecasts then stale.

### 4.3 Kiosk history panels (the #165/#198 dashboard work — cross-referenced, not done here)

For each **covered / mapped** series, the panel Flux query changes to read the
`jupiter_*` measurement, **unioned with the `zeus_*` series** so the line is
continuous across the ~2026-07-04 cutover, e.g.:

```
from(bucket: "zeus") |> range(...)
  |> filter(fn: (r) =>
       (r._measurement == "jupiter_state" or r._measurement == "zeus_state")
       and r._field == "soc_pct")
```

Apply the field rename (`import_price_eur` → `import_price_eur_per_kwh`), the
`zeus_savings.today_eur` → `jupiter_state.savings_today_eur` relocation, and drop
the `* 4` on the forecast panels (per-hour vs per-slot). For the **gap** series,
#165/#198 decides per panel: retire the panel, or accept it goes flat-after-cutover
reading the retained archive, or wait on a jupiter writer extension (4.2 / the
savings-breakdown fields).

### 4.4 Optional, before decommission

Run **#168** (`site_id` backfill) so archive + live share one site-filtered query
path and the trainer's `include_untagged` flag can be retired.

---

## 5. HARD GATE to add to #169 (zeus decommission)

**Add this as a blocking pre-condition on #169:**

> **#169 must scale zeus to 0 and MUST NOT delete or drop any InfluxDB data.**
> Specifically: do NOT run `influx delete`, do NOT drop any `zeus_*` measurement,
> do NOT delete the `influxdb-influxdb2` PVC, and do NOT let a `local-path`
> `Delete`-reclaim PVC deletion take the volume. The `zeus` bucket is retained
> read-only after decommission. "Retire `zeus_*`" in the #169 title means **stop
> writing** (pod→0), **not** delete the historical series. Deleting the bucket is
> gated behind explicit owner sign-off that history preservation (this card) is
> complete — and given infinite retention + the kiosk panels reading it, the
> default is **never delete**.

### What is LOST if someone deletes the `zeus` bucket at decommission

- **All battery history** — months of SoC, mode, import price, daily & today
  savings, capacity, and the entire frozen single-field archive (2026-06-28 and
  earlier). None of it exists under `jupiter_*` (jupiter's series only start
  ~2026-07-04). The kiosk history / monthly / savings-economics / consumption /
  forecast-accuracy panels go blank for everything before the cutover.
- **The forecast trainer's entire training corpus** — `zeus_load_history`
  (kwh/ac_kwh) and `zeus_state.grid_power_w` are **only** in the zeus bucket and
  are **not** written by jupiter. Deleting them leaves the forecast-service unable
  to train; it degrades to serving its last artifact until that stales
  (`jupiter_forecast_artifact_age_seconds` alert) → **forecast quality, and hence
  optimization/savings quality, degrades.** This is a live-adjacent loss, not
  cosmetic.
- **The #164 savings-parity evidence base** and any future audit of the
  zeus→jupiter handover — the only durable record of zeus's realized numbers.

Recovery after a delete is limited to whatever sits in the NAS backups (14-day
full / 3-day incremental retention) — i.e. anything older than 14 days is
**unrecoverable**. Hence: **retain the bucket; deletion is never part of #169.**

---

## 6. Cross-references

- **#165 / #198** — Prometheus + dashboard-query side of the kiosk migration;
  owns the panel Flux edits in Section 4.3.
- **#168** — `platform/influxdb-config/RUNBOOK-site-id-backfill.md`; `site_id`
  backfill of the frozen archive (optional, recommended pre-decommission).
- **#170 / #171** — sourced `jupiter_state` / `jupiter_daily_savings` from
  jupiter's own inputs (why `grid_power_w` is dropped).
- **#182** — `platform/influxdb-config/RUNBOOK-longhorn-migration.md`; move the
  InfluxDB PVC to redundant storage; land before decommission if possible.
- **#169** — the decommission; carries the hard gate in Section 5.
- Jupiter-repo follow-up (not gitops): extend a writer to emit
  `jupiter_load_history` (Section 4.2 A) so the trainer survives decommission.

Card: https://trello.com/c/F0BFqj7c
