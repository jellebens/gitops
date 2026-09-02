# PLAN — kiosk dashboard `zeus_*` → jupiter migration

**Status:** REFRESHED 2026-07-20 against live Prometheus (read-only PromQL via a
port-forward to `kube-prometheus-stack-prometheus`). This supersedes the original
"P4 tail" draft, which predated (a) the dashboard renames, (b) the now-live
`jupiter_reporting_*` namespace, `jupiter_savings_*` family, and
`jupiter_savings_today_eur`, and (c) the #164 savings-parity sign-off. The old
draft's central claim — *"jupiter_lar_* is a skeleton that emits no savings and
no SoC/energy, so a name-for-name migration is impossible"* — is **no longer
true**. A reporting-service now mirrors most kiosk series as `jupiter_reporting_*`
and a savings-service emits `jupiter_savings_*`, all `site_id=tervuren`, all
verified emitting live.

This doc is the spec for the tranche-2 query migration (card #198). Tranche 1
(#165 / gitops PR #222) already migrated the OK-mapped **health/plan** series
(target charge/discharge, last-cycle timestamp, control-available) to
`jupiter_lar_*` in `battery-kiosk.json`, `mission-control.json`,
`ops-resources-use.json`.

---

## Superseded rule: savings source of truth

Prior guidance pinned savings to zeus (`zeus_battery_savings_today` /
`zeus_savings_today_eur`) as the incumbent controller-agnostic figure. **As of
2026-07-20 that is SUPERSEDED.** The jupiter reporting-service is now the live
savings source of truth: `jupiter_reporting_savings_source{source="independent"} = 1`
(verified live), and the #164 savings-parity soak signed off 2026-07-20
(certified **savings-parity only, NOT logic-equivalence**). Savings tiles
therefore migrate to `jupiter_savings_today_eur`.

Caveat that follows directly from "parity, not logic-equivalence": the headline
**net** savings agree within tolerance, but the **decomposition** series
(baseline/actual cost, charged/discharged kWh) do **not** — see the divergence
note below.

---

## Dashboard renames (old draft → current files)

The old draft referenced pre-rename filenames. Current files under
`landingzones/zeus/dashboards/`:

| Old draft name | Current file |
|---|---|
| `zeus-kiosk.json` | `battery-kiosk.json` |
| `zeus-kiosk-ops.json` | `ops-kiosk.json` (+ `mission-control.json`) |
| `zeus.json` (ops) | `battery-optimizer.json` |
| `zeus-monthly-influx.json` | `battery-monthly.json` |
| `zeus-forecast-influx.json` | `forecast-history.json` |
| (price ops) | `price-grid.json` |
| (savings ops) | `savings-economics.json` |
| `home-energy-ha.json` | `home-energy-ha.json` (unchanged) |

Other files: `consumption-analysis.json`, `gitops-data-health.json`,
`forecast-accuracy.json`, `jupiter-services.json`, `ops-resources-use.json`.

---

## Live jupiter series (verified emitting 2026-07-20, all `site_id=tervuren`)

The live tervuren controller emits `jupiter_lar_*` (note: `jupiter_cell_*` names
exist in the metric index but return **no live samples** — a stale prefix; do not
target them). Verified-emitting families relevant to the kiosk:

- `jupiter_reporting_*` — kiosk mirror: `soc_percent`, `energy_stored_kwh`,
  `price_position_pct`, `import_price_eur_per_kwh`, `capacity_peak_kw`,
  `target_charge_kw`, `target_discharge_kw`, `price_source` (enum-as-label),
  `forecast_source` (enum-as-label), `savings_source` (enum-as-label),
  `controller`, plan metadata. **`jupiter_reporting_grid_power_w` exists in the
  index but is NOT emitting** (no live sample).
- `jupiter_savings_*` — `today_eur`, `actual_eur`, `baseline_eur`,
  `charged_today_kwh`, `discharged_today_kwh`, plus parity metrics
  (`parity_abs_eur`, `parity_signed_eur`, `parity_rel_ratio`).
- `jupiter_lar_*` — live-controller state: `soc_pct`, `actual_mode` (0/1/2),
  `target_charge_kw`, `target_discharge_kw`, `plan_cost_eur`,
  `control_available`, `last_cycle_timestamp_seconds`,
  `cycles_total{outcome=...}` (only `outcome="planned"` currently emits),
  `price_source` (0/1/2 code), `live_actuating`, spike-responder series.
- Standalone: `jupiter_quarter_mean_kw`, `jupiter_quarter_headroom_kw`,
  `jupiter_charge_guard_trips_total`.

---

## Live cross-check (zeus vs jupiter, same physical battery)

Instant values sampled 2026-07-20 confirm which mappings are drop-in safe. Same
battery → matching values validate the mapping; divergent values flag a
definitional mismatch.

| Series | zeus value | jupiter value | verdict |
|---|---|---|---|
| soc | 68 | `jupiter_lar_soc_pct` 68 | **match** |
| actual_mode | 1 | `jupiter_lar_actual_mode` 1 (range 0-2 = IDLE/CHARGING/DISCHARGING, matches panel mappings) | **match** |
| energy_stored | 8.84 | `jupiter_reporting_energy_stored_kwh` 9.22 | **match** (sampling noise) |
| price_position_pct | 0 | `jupiter_reporting_price_position_pct` 0 | **match** |
| import_price | 0.004293 | `jupiter_reporting_import_price_eur_per_kwh` 0.004293 | **exact match** |
| capacity_peak | 5.928 | `jupiter_reporting_capacity_peak_kw` 5.928 | **exact match** |
| quarter_mean_kw | 1.9656 | `jupiter_quarter_mean_kw` 1.9645 | **match** |
| quarter_headroom_kw | 3.9629 | `jupiter_quarter_headroom_kw` 3.9684 | **match** |
| charge_guard_trips | 0 | `jupiter_charge_guard_trips_total` 0 | **match** |
| savings_today_eur | 0.6027 | `jupiter_savings_today_eur` 0.5569 | **match** (parity, #164) |
| **charged_today_kwh** | **10.783** | `jupiter_savings_charged_today_kwh` **5.763** | **DIVERGE ~2x** |
| **discharged_today_kwh** | **9.626** | `jupiter_savings_discharged_today_kwh` **4.609** | **DIVERGE ~2x** |
| **baseline_cost** | **1.088** | `jupiter_savings_baseline_eur` **0.685** | **DIVERGE** |
| **actual_cost** | **0.5997** | `jupiter_savings_actual_eur` **0.2416** | **DIVERGE** |
| **price_source** | **4** | `jupiter_lar_price_source` **0** | **DIFFERENT ENUM** |
| **grid_power_w** | 1964.6 | `jupiter_reporting_grid_power_w` | **NOT EMITTING** |

The decomposition divergence is exactly the #164 caveat ("savings-parity, not
logic-equivalence"): jupiter's reporting-service reaches the same *net* savings
via a different baseline/actual accounting basis than zeus. Silently swapping the
decomposition tiles would show materially different (2x) numbers on a live kiosk
with no validation — so those tiles stay on zeus_ pending a reconciliation card.

---

## Migration map (tranche-2 scope)

**MIGRATE** — verified emitting + semantically matching, single tervuren series so
`max(...)` is a clean drop-in:

| `zeus_*` | -> jupiter | tier |
|---|---|---|
| `zeus_soc_percent` | `jupiter_lar_soc_pct` | SoC |
| `zeus_actual_mode_code` | `jupiter_lar_actual_mode` | mode |
| `zeus_energy_stored_kwh` | `jupiter_reporting_energy_stored_kwh` | energy |
| `zeus_price_position_pct` | `jupiter_reporting_price_position_pct` | price |
| `zeus_import_price_eur_per_kwh` | `jupiter_reporting_import_price_eur_per_kwh` | price |
| `zeus_capacity_peak_kw` | `jupiter_reporting_capacity_peak_kw` | capacity |
| `zeus_quarter_mean_kw` | `jupiter_quarter_mean_kw` | capacity |
| `zeus_quarter_headroom_kw` | `jupiter_quarter_headroom_kw` | capacity |
| `zeus_charge_guard_trips_total` | `jupiter_charge_guard_trips_total` | capacity |
| `zeus_savings_today_eur` | `jupiter_savings_today_eur` | savings |

**GAP — leave on `zeus_*`, note reason** (would blank or mislead a live tile):

| `zeus_*` | reason |
|---|---|
| `zeus_grid_power_w` | `jupiter_reporting_grid_power_w` exists in index but emits no live sample |
| `zeus_price_source` | jupiter enum differs (zeus code 4 vs `jupiter_lar_price_source` 0/1/2; `jupiter_reporting_price_source` is enum-as-label). Needs panel value-mapping rework, not a query swap |
| `zeus_energy_charged_today_kwh` | ~2x divergence vs `jupiter_savings_charged_today_kwh` (accounting basis differs) |
| `zeus_energy_discharged_today_kwh` | ~2x divergence vs `jupiter_savings_discharged_today_kwh` |
| `zeus_baseline_cost_today_eur` | ~1.6x divergence vs `jupiter_savings_baseline_eur` |
| `zeus_actual_cost_today_eur` | ~2.5x divergence vs `jupiter_savings_actual_eur` |
| `zeus_working_mode` | stateset (`max by (mode)`) — `jupiter_lar_actual_mode` is a single code, different shape |
| `zeus_next_charge_in_seconds` / `..._discharge_...` | no jupiter equivalent |
| `zeus_cycle_failures_total` | `jupiter_lar_cycles_total{outcome="error"}` does not emit (only `outcome="planned"` exists) |
| `zeus_solver_optimal` | no jupiter boolean equivalent |
| `zeus_price_now_marker_eur_per_kwh` / `zeus_price_today_eur_per_kwh` / `zeus_price_horizon_eur_per_kwh` | per-slot price curve — jupiter price-service exposes `jupiter_price_curve_points` (a count) but no scrapeable per-slot curve series |
| `zeus_price_degraded_total` | no jupiter equivalent |
| `zeus_predicted_peak_kw` | no jupiter equivalent |
| `zeus_shaving_miss_total` | no jupiter equivalent |

**#222 health/plan family — NOT tranche-2** (leave for the tranche that finishes
#222's category; already migrated in the 3 files #222 touched, still on `zeus_*`
in `battery-optimizer.json` / `ops-kiosk.json` where #222 did not reach):
`zeus_target_charge_kw`, `zeus_target_discharge_kw`, `zeus_plan_cost_eur`,
`zeus_control_available`, `zeus_last_cycle_timestamp_seconds`.

**Out of scope entirely:**
- **All InfluxDB-datasource panels** (card #199, historical-data preservation):
  every Flux/`zeus_state`/`zeus_daily_savings`/`zeus_savings` target in
  `gitops-data-health.json`, `ops-kiosk.json`, `battery-monthly.json`,
  `forecast-history.json`, `consumption-analysis.json`, `savings-economics.json`,
  `home-energy-ha.json`. jupiter has **no InfluxDB writer**, so these series only
  exist under zeus — the decision (jupiter InfluxDB writer vs retire-with-zeus)
  is #199's, gated before #169.
- `forecast-accuracy.json`, `jupiter-services.json`.

---

## Panels migrated in tranche 2 (per file)

- **battery-kiosk.json**: SoC, Mode (live), Stored, Cheap->Expensive, Savings today.
- **mission-control.json**: SoC, Mode (live), Stored, Price now, Cheap->Expensive,
  Savings today, Billed peak.
- **ops-kiosk.json**: Battery (composite: mode/price-pos/soc), Grid power (refId B
  = capacity_peak), Capacity peak (W).
- **battery-optimizer.json**: Battery SoC, State of charge, Savings today, Savings
  today (running), Import price, Capacity tariff peak, Capacity cross-check
  (refId B).
- **price-grid.json**: Import price now, Now cheap->expensive, Cheap->expensive
  strip, Current quarter mean, Quarter headroom, Billed peak this month,
  Charge-guard trips (range), Quarter-hour peak tracking (refId B quarter_mean,
  refId C capacity_peak), Charge-guard trips & shaving misses (refId A).
- **savings-economics.json**: Savings today (the one Prometheus panel).

**HARD RULE honored:** every edit is a `targets[].expr` string swap on a
Prometheus target only. No `gridPos`, no panel move/resize/reflow, no datasource
type change (all already `prometheus`). Proven by jq gridPos-diff vs
`origin/develop`.

---

## Remaining decommission blockers (before #169, ~2026-08-06)

1. **InfluxDB history has no jupiter writer** (#199) — the `zeus_state` /
   `zeus_daily_savings` history panels blank when zeus stops unless jupiter grows
   an InfluxDB writer or the panels are rebuilt/retired.
2. **grid_power_w** — needs `jupiter_reporting_grid_power_w` to actually emit.
3. **price_source / forecast_source** — enum reshape (numeric code vs
   enum-as-label) requires panel value-mapping rework.
4. **energy/cost decomposition** (charged/discharged, baseline/actual) — reconcile
   the ~2x accounting divergence and decide the source of truth (ties to #197
   logic-equivalence A/B).
5. **per-slot price curve** (marker/today/horizon) — needs a scrapeable jupiter
   series.
6. **next-charge/discharge countdowns, predicted_peak, shaving_miss,
   solver_optimal, cycle error counter** — no jupiter equivalent yet.
7. **#222 health/plan tail** in `battery-optimizer.json` / `ops-kiosk.json`
   (target/plan_cost/control/last_cycle) — finish that category's migration.
