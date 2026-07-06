# PLAN — dashboard `zeus_*` → `jupiter_lar_*` migration (P4 tail)

**Status:** PLAN only. **No dashboard was touched, reflowed, or edited.** Kiosk
layout is a HARD-rule no-go for this work. This document inventories the current
`zeus_*` usage, maps it to `jupiter_lar_*`, flags the gaps, and sequences a
cutover that is gated on zeus decommission (~August). It is deliberately
actionable-but-not-executed.

**Decision context:** ADR-0022 (`jupiter_*` namespace + `zeus_*` dual-emit
continuity, D3) and ADR-0023 (zeus stays running as a live cross-check;
single-controller interlock keys on zeus's `commander` signal). Read those two
first — the migration timing hangs entirely on the ADR-0023 end state.

---

## The finding that reframes this whole plan

ADR-0022 assumed the classic cutover: at go-live zeus goes to `replicas: 0`, and
the lar turns **ON** a `zeus_*` **dual-emit** alias so dashboards keep working
without a gap, then migrate to `jupiter_*` one at a time.

**That is not what went live.** ADR-0023 (the actual 2026-07-06 go-live decision)
kept **zeus running, demoted** (`control.enabled: false`, `commander == 0`). zeus
therefore **keeps emitting every `zeus_*` series it always did**, including the
savings source of truth. Consequences for this plan:

- **The lar's `zeus_*` dual-emit is NOT on** (and must not be) — if the lar also
  emitted `zeus_*` for tervuren while zeus is still emitting them, the two would
  collide and poison `max()`/`last()` aggregations. Verified against the live
  lar code (`services/lar/jupiter_lar/metrics.py`): the lar emits **only**
  `jupiter_lar_*`, no `zeus_*` alias. ADR-0023 §Consequences confirms: "zeus
  keeps emitting `zeus_*` including the savings series, so the kiosk source of
  truth never gaps."
- **Therefore the dashboards do NOT need to change during the soak.** They keep
  reading `zeus_*` from the still-running zeus. The migration to `jupiter_lar_*`
  is **gated on zeus decommission** (the eventual `replicas: 0`, ~August) — the
  moment `zeus_*` stops being produced is the moment the dashboards must already
  be on `jupiter_lar_*` (or the lar's dual-emit must be turned on as a bridge).

So this is a *pre-staged* migration: build/verify the `jupiter_lar_*` panels now
against the live shadow/live lar metrics, but do not flip the kiosk until the
decommission card.

## The gap that blocks a clean cutover (most important)

**`jupiter_lar_*` today is a SKELETON metric set. It does not emit most of what
the kiosk needs, and it emits NO savings series at all.**

The live lar exposes exactly these Prometheus series (from
`services/lar/jupiter_lar/metrics.py`, every one labeled `site_id`):

```
jupiter_lar_cycles_total{site_id,outcome}
jupiter_lar_plan_cost_eur{site_id}
jupiter_lar_target_charge_kw{site_id}
jupiter_lar_target_discharge_kw{site_id}
jupiter_lar_price_source{site_id}          # 0=primary 1=cache 2=none
jupiter_lar_forecast_source{site_id}       # 0=primary 1=cache 2=none
jupiter_lar_last_cycle_timestamp_seconds{site_id}
jupiter_lar_build_info{version}
jupiter_lar_control_available{site_id}
jupiter_lar_actual_mode{site_id}
jupiter_lar_live_actuating{site_id}
jupiter_lar_ha_read_ok / jupiter_lar_ha_read_errors_total{site_id}
```

Its own metrics docstring says so: *"This is a SKELETON metric set … The rich
per-slot plan/savings/peak series (the zeus `zeus_*` set) … land with the
plan-doc + publish card (#140)."* The lar's richer state (SoC, per-slot plan) is
published **to MQTT** (`jupiter/<site_id>/plan`, `…/heartbeat`) and is **not** a
Prometheus series a Grafana panel can scrape today. The lar does **not** write to
InfluxDB at all (its `degraded.influx` flag is a placeholder).

**Net:** a straight name-for-name kiosk migration is **impossible right now** —
the target series mostly don't exist yet. This plan therefore has a hard
dependency on a jupiter metrics-parity card (the `#140`/`#137` line of work)
before the kiosk can move.

---

## Inventory: `zeus_*` series in use, by dashboard and datasource

Verified by parsing every dashboard JSON under
`landingzones/zeus/dashboards/`. **No dashboard filters on `site_id`** (0 refs),
so the backfill and any per-site work are non-breaking here.

### `zeus-kiosk-ops.json` (the live kiosk)
- **Prometheus (all live tiles):** `zeus_soc_percent`, `zeus_grid_power_w`,
  `zeus_capacity_peak_kw`, `zeus_actual_mode_code`, `zeus_price_position_pct`,
  `zeus_control_available`, `zeus_cycle_failures_total`,
  `zeus_last_cycle_timestamp_seconds`, `zeus_solver_optimal`.
- **InfluxDB (one panel):** "Consumption heatmap (kW)" reads `zeus_state`
  (the live, `site_id=tervuren`-tagged wide measurement).

### `zeus-kiosk.json`
- **Prometheus:** `zeus_soc_percent`, `zeus_savings_today_eur`,
  `zeus_energy_stored_kwh`, `zeus_energy_charged_today_kwh`,
  `zeus_energy_discharged_today_kwh`, `zeus_target_charge_kw`,
  `zeus_target_discharge_kw`, `zeus_actual_mode_code`,
  `zeus_price_position_pct`, `zeus_next_charge_in_seconds`,
  `zeus_next_discharge_in_seconds`, `zeus_cycle_failures_total`,
  `zeus_last_cycle_timestamp_seconds`.

### `zeus.json` (ops dashboard)
- **Prometheus:** savings/cost (`zeus_savings_today_eur`,
  `zeus_actual_cost_today_eur`, `zeus_baseline_cost_today_eur`,
  `zeus_plan_cost_eur`), price (`zeus_price_today_eur_per_kwh`,
  `zeus_price_now_marker_eur_per_kwh`, `zeus_import_price_eur_per_kwh`),
  `zeus_soc_percent`, `zeus_working_mode`, `zeus_target_charge_kw`,
  `zeus_target_discharge_kw`, `zeus_grid_power_w`, `zeus_capacity_peak_kw`,
  energy, cycle/health series.

### `ops-resources-use.json`
- **Prometheus:** `zeus_control_available`, `zeus_cycle_failures_total`,
  `zeus_last_cycle_timestamp_seconds`, `zeus_solver_optimal`.

### `zeus-monthly-influx.json` (bucket `zeus`)
- **InfluxDB:** `zeus_state`, `zeus_daily_savings`, `zeus_forecast`,
  `zeus_forecast_frozen`, `zeus_forecast_load_kwh`, `zeus_load_history`,
  `zeus_realized_load_kwh`, `zeus_soc_percent`, `zeus_grid_power_w`,
  `zeus_mode_code`, `zeus_capacity_peak_kw`, `zeus_import_price_eur_per_kwh`.

### `zeus-forecast-influx.json` (bucket `zeus`)
- **InfluxDB:** `zeus_forecast`, `zeus_state`,
  `zeus_predicted_baseline_cost_eur`, `zeus_predicted_optimized_cost_eur`,
  `zeus_predicted_savings_eur`.

### `home-energy-ha.json` (bucket `homeassistant`)
- **InfluxDB (HA recorder path):** `entity_id="zeus_battery_savings_today"`
  (savings source of truth), `zeus_actual_cost_today`,
  `zeus_baseline_cost_today`. These are HA sensors, not zeus/lar Prometheus
  series — a different migration story (see §Savings continuity).

---

## Mapping: `zeus_*` → `jupiter_lar_*`, with gaps

Legend: **OK** = lar emits an equivalent Prometheus series today; **MQTT-only** =
the value exists in the lar's MQTT plan/heartbeat doc but is NOT a Prometheus
series a panel can scrape; **GAP** = the lar does not produce it anywhere yet.

| Kiosk/ops `zeus_*` | jupiter-lar equivalent | State |
|---|---|---|
| `zeus_target_charge_kw` | `jupiter_lar_target_charge_kw{site_id}` | **OK** |
| `zeus_target_discharge_kw` | `jupiter_lar_target_discharge_kw{site_id}` | **OK** |
| `zeus_plan_cost_eur` | `jupiter_lar_plan_cost_eur{site_id}` | **OK** |
| `zeus_control_available` | `jupiter_lar_control_available{site_id}` | **OK** |
| `zeus_actual_mode_code` | `jupiter_lar_actual_mode{site_id}` | **OK** (verify enum mapping) |
| `zeus_last_cycle_timestamp_seconds` | `jupiter_lar_last_cycle_timestamp_seconds{site_id}` | **OK** |
| `zeus_cycle_failures_total` | `jupiter_lar_cycles_total{site_id,outcome="error"}` | **OK** (derive from `outcome`) |
| `zeus_solver_optimal` | (implied by `jupiter_lar_cycles_total{outcome="planned"}`) | **partial** — no direct boolean; derive or add |
| `zeus_soc_percent` | `soc_pct` in the MQTT plan doc | **MQTT-only** (no Prom series) |
| `zeus_energy_stored_kwh` | `plan.soc_kwh[0]` in MQTT plan doc | **MQTT-only** |
| `zeus_grid_power_w` | (read from HA; lar reads it but doesn't republish as a metric) | **GAP** |
| `zeus_capacity_peak_kw` | `running_peak_kw` in MQTT plan `inputs` | **MQTT-only** |
| `zeus_price_position_pct` | — | **GAP** |
| `zeus_price_today_eur_per_kwh` / marker | — (price lives in the price-service; lar emits only `price_source` enum) | **GAP** |
| `zeus_import_price_eur_per_kwh` | `import_price_eur` field in `zeus_state` (InfluxDB) | zeus-owned; **GAP** on lar side |
| `zeus_next_charge_in_seconds` / `..._discharge_..` | — | **GAP** |
| `zeus_working_mode` | `jupiter_lar_actual_mode{site_id}` | **partial** |
| **`zeus_savings_today_eur`** | — | **GAP (critical)** |
| **`zeus_battery_savings_today`** (HA sensor) | — | **GAP (critical)** |
| `zeus_actual_cost_today_eur` / `zeus_baseline_cost_today_eur` | — | **GAP** |
| `zeus_predicted_savings_eur` / baseline / optimized | — | **GAP** |
| `zeus_daily_savings`, `zeus_savings` (InfluxDB history) | — | **GAP** |
| `zeus_forecast*`, `zeus_load_history`, `zeus_realized_load_kwh` | — (forecast lives in the central forecast-service; lar emits `forecast_source` enum only) | **GAP** on lar side |
| `zeus_state` (wide InfluxDB measurement) | — (no lar InfluxDB writer at all) | **GAP** |

### The critical gap: savings + battery-state

- **jupiter-lar emits NO savings series** — not `savings_today`, not a predicted
  or baseline cost, nothing. Savings is entirely a **GAP**.
- **jupiter-lar emits NO Prometheus SoC / energy-stored / grid-power series** —
  those values exist only inside the MQTT plan document, which Grafana cannot
  scrape as-is.
- **jupiter-lar writes nothing to InfluxDB** — so the `zeus_state`-backed
  InfluxDB panels (kiosk heatmap, monthly, forecast dashboards) have **no lar
  data source** whatsoever.

**What would need building before the kiosk can leave `zeus_*`:**
1. A jupiter metrics-parity pass (the `#140`/`#137` line) that promotes the
   MQTT-only values (`soc_pct`, energy-stored, per-slot plan, running peak) to
   Prometheus `jupiter_lar_*` gauges, and adds the missing live gauges
   (grid power, price position, next-charge/discharge countdowns).
2. A **savings computation + emission** owner for jupiter (see §Savings
   continuity — this is a design decision, not just a rename).
3. If any InfluxDB-backed panel is to move off `zeus_state`, a jupiter InfluxDB
   writer (site-tagged, per ADR-0019) emitting the equivalent wide measurement —
   or those panels stay on the (frozen-then-decommissioned) `zeus_state` and get
   rebuilt against the new series.

---

## Savings-continuity question (explicit)

**The question:** post-cutover, zeus — as the demoted live check — still computes
`zeus_battery_savings_today` from the actual battery behavior that **jupiter now
drives**. Is that still the right source of truth, or should jupiter-lar own
savings before zeus is decommissioned?

**The facts:**
- zeus's savings is computed from *observed* battery/grid behavior (HA sensors +
  price curve), **not** from who issued the command. Since the lar now drives the
  battery, zeus's `zeus_battery_savings_today` is *already measuring the lar's
  results* — it is an honest, controller-agnostic savings figure today.
- jupiter-lar has **no** savings series and no savings model wired.
- Both the Prometheus `zeus_savings_today_eur` and the HA-sensor
  `zeus_battery_savings_today` (source of truth) are still fresh and live
  (verified: HA sensor writing at 2026-07-06 17:30).

**Recommendation:**
1. **During the soak (now → ~August): keep zeus as the savings source of
   truth.** It is controller-agnostic (measures realized behavior, not who
   commanded), it is the incumbent with a year of continuous history, and
   ADR-0023 explicitly keeps it emitting for exactly this reason. Do **not** rush
   a jupiter savings series while zeus is warm — a second savings computation
   during the soak just invites a divergence to explain.
2. **Before zeus decommission, jupiter must take over savings** — otherwise the
   source of truth vanishes with zeus. The clean design is a **central savings
   owner** (not the per-site lar): savings is a reporting/accounting concern that
   reads the realized battery series + the price curve, which is exactly the
   central-services shape jupiter already uses for price/forecast. Building it
   central (site-tagged `jupiter_savings_today{site_id}` + an InfluxDB history
   series) keeps it fleet-ready and off the lar's safety-critical control path.
   The lar staying savings-free is a feature: nothing on the actuation path
   should depend on a reporting computation.
3. **Cross-check overlap:** run the jupiter savings series in parallel with
   zeus's for at least a soak window, diff them (they should agree, since both
   read the same realized behavior), and only then flip the kiosk's savings panel
   and retire `zeus_battery_savings_today`. This is the savings-series-continuity
   requirement ADR-0022 calls out ("the daily savings history must read
   unbroken — it is the kiosk's source of truth").

**Bottom line:** zeus stays the savings source of truth through the soak;
jupiter should own savings **centrally** (not in the lar) as a pre-decommission
deliverable, verified against zeus before the kiosk's savings panel migrates.

---

## Migration sequence (recommended order)

Both `zeus_*` and `jupiter_lar_*` coexist during the soak. Nothing on the kiosk
moves until the decommission gate. Order:

**Phase A — during the soak (no dashboard edits to the live kiosk).**
- A0. Land the jupiter metrics-parity work (#140/#137): promote MQTT-only lar
  values to Prometheus `jupiter_lar_*` gauges; add the missing live gauges;
  decide the InfluxDB-writer question. **Blocks everything below.**
- A1. Land the central jupiter savings owner (see §Savings continuity), running
  in parallel with zeus for cross-check.
- A2. Build a **parallel** "jupiter" copy of the ops dashboard (a NEW dashboard,
  not an edit of the kiosk) wired to `jupiter_lar_*` with a `site_id` template
  variable. This is where you validate parity visually without touching the
  kiosk. (New file under `landingzones/zeus/dashboards/` or a jupiter landing
  zone — additive, no reflow of anything existing.)
- A3. For InfluxDB history panels, keep them on `zeus_state` (still live +
  tagged). If a jupiter InfluxDB writer lands, add its series alongside and use
  the ADR-0019 transition predicate.

**Phase B — dual-source transition panels (still no kiosk reflow).**
- For each parity-verified series, make the corresponding NEW-dashboard panel a
  **dual-source** query: `max(zeus_X or jupiter_lar_X_equivalent)` (or an
  explicit two-query overlay), so the panel is correct whether the value comes
  from zeus or the lar. This makes the eventual zeus-off flip a no-op for those
  panels. Candidate dual-source panels first: target charge/discharge, plan cost,
  control-available, mode, cycle/last-cycle health — the **OK**-mapped series.

**Phase C — cutover, GATED on zeus decommission (~August).**
- Only when zeus goes `replicas: 0` (the decommission card) does `zeus_*` stop.
  At that gate, either (a) the kiosk has already been re-pointed to
  `jupiter_lar_*` (preferred — do the re-point as a scoped, panel-by-panel edit
  that changes only the query/datasource, **never the gridPos**), or (b) the lar
  turns on `zeus_*` dual-emit as a temporary bridge (ADR-0022's original
  mechanism) so the kiosk keeps working while panels migrate one at a time.
- Migrate **one dashboard / one panel at a time**, grep-verifying which `zeus_*`
  names are still queried after each step. Retire a dual-emitted / zeus name only
  when nothing queries it (per-dashboard, not per-calendar — ADR-0022 §4).
- **HARD rule throughout: query/datasource edits only; never move, resize, or
  reflow a tile.** Each panel migration is a scoped change to that panel's
  `targets[]`, nothing else.

**Recommended first migrations (lowest risk, highest parity):** the **OK**-mapped
health/plan series (`target_charge_kw`, `target_discharge_kw`, `plan_cost_eur`,
`control_available`, `actual_mode`, `last_cycle_timestamp`, cycle counters).
**Last / most-blocked:** savings + SoC + InfluxDB-history panels, which depend on
the parity build (A0) and the central savings owner (A1).

## Open items to file as cards (out of scope for this PLAN)
- Jupiter metrics-parity: promote lar MQTT-only values to Prometheus + add
  missing live gauges (blocks the kiosk migration).
- Central jupiter savings owner + InfluxDB history (blocks retiring the zeus
  savings source of truth).
- Decision: does jupiter write to InfluxDB (a site-tagged wide measurement
  mirroring `zeus_state`) for the history/heatmap panels, or are those panels
  rebuilt against Prometheus/new series?
- HA-side: if the `homeassistant`-bucket savings sensor is to survive zeus, its
  HA source (`sensor.zeus_battery_savings_today`) needs a jupiter-fed
  replacement — a hestia (HA-config) concern.
