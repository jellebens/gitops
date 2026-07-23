# #177 spike-responder activation — threshold experiment

**Date:** 2026-07-23 · **Site:** tervuren · **Card:** #177 (depends on #178)
**Outcome:** responder flipped `observe` → **`active`**, trigger **2.5 → 2.0 kW**,
release 1.0 kW, cooldown 120 s. Owner-approved.

---

## 1. Question

The spike responder had been sitting in `observe` since 2026-07-10. Two things
had to be settled before flipping it to `active`:

1. **Is it safe to activate?** The 2026-07-10 analysis
   ([`jupiter/docs/analysis/2026-07-10-spike-thresholds.md`](https://github.com/jellebens/jupiter))
   set a hard gate: *do not activate on the raw signal*, because whole-home
   import includes the battery's own charging (~2.2 kW) and the responder would
   mode-flap every ~2.5 min through every charge window.
2. **Which thresholds maximise savings?** The original 2.5 / 1.0 came from a
   10.6-day simulation optimising for *event rate*, not for money.

## 2. Pre-flight gates (both PASS)

| Gate | Evidence |
|---|---|
| #178 signal decontamination deployed | `jupiter-lar:0.14.0` contains `ha_state.py:478 ent_batt = cfg.entities.battery_grid_input`, plus `spike.py` / `config.py` references |
| `entities.battery_grid_input` configured | `landingzones/jupiter-tervuren/values.yaml` → `sensor.buzzbrick_ap3002532000565690_grid_input_power` |
| Fail-safe on read miss | log: *"spike battery grid-input read failed (no sample — a configured correction never degrades to the raw contaminated signal)"* — on a battery read miss it emits **no sample** rather than falling back to the contaminated one |

Observe-phase counters at analysis time: `would_trigger_total=8`,
`cooldown_suppressed_total{transition="trigger"}=14`, `spike_state=0`.
(More suppressed than fired — the signal crosses the threshold in bursts.)

## 3. Method

- **Source:** InfluxDB `homeassistant` bucket (HA recorder), measurement `W`, field `value`.
- **Window:** 2026-07-09 09:53 → 2026-07-23 09:52 UTC — **14.0 days, 20 160 minutes**.
- **Signals:**
  - `utility_room_home_energy_meter_electric_consumption_w` — billed grid import
  - `buzzbrick_ap3002532000565690_grid_input_power` — battery charging from grid
  - `buzzbrick_ap3002532000565690_alternating_current_out_power` — AC-out load
- **Resampling:** `aggregateWindow(every: 1m, fn: mean)`, then **LOCF** fill onto a
  continuous 1-minute grid (HA records on-change, so gaps mean "unchanged", not
  zero — same convention as `jupiter_dispatch.energy.resample_locf`).
- **Corrected house draw:** `house = max(0, import − battery_charging)`.
- **Simulation:** the responder state machine (trigger → discharging → release →
  120 s cooldown) replayed at 1-min resolution over the sweep grid.
- **Savings model:** the Flemish **capacity tariff bills the peak quarter-hour
  mean**, at ≈ €4/kW/month. For each config the modified import series is
  re-blocked into 15-min means and the peak compared to baseline.
- **Responder effect while discharging:** battery charging stops (import loses
  `battery_charging`) and the battery serves what it physically can of the
  AC-out load: `import' = max(0, house − min(3.84 kW, ac_out))`.

### 3.1 Data-quality fix that changed the result

The raw series contained **one minute reading 60.02 kW** — impossible on a
residential connection (meter glitch). A single bogus minute contributes
60/15 = 4 kW to a 15-min mean, so it *fabricated the capacity peak* and made
every config look worthless (Δpeak ≈ 0.05 kW). Filtering readings > 15 kW
(carry-previous) changed the headline result from **0.05 kW to 1.44 kW**.

> Lesson worth keeping: any capacity-peak work on this meter must de-glitch
> first, or it will silently measure the sensor instead of the house.

## 4. Results

**Baseline (de-glitched):** billed import p50 0.58 / p95 2.34 / max 5.52 kW.
Corrected house p50 0.19 / p95 0.97 / max 4.23 kW. Battery charging max 2.17 kW,
active in 13 098 of 20 160 minutes (**65 % of the time**). AC-out p50 0.56 / p90 1.60 kW.
Top-5 baseline quarter-hours: **4.43, 3.94, 3.94, 3.91, 3.80 kW**.

### 4.1 The headline finding

**The capacity peak is not caused by big appliances — it is house load with
battery charging stacked on top.**

| Quarter-hour | Import | House | Charging | Charging share |
|---|---|---|---|---|
| 2026-07-22 14:38 | 4.43 | 2.34 | 2.10 | **47 %** |
| 2026-07-22 14:23 | 3.94 | 1.82 | 2.12 | **54 %** |
| 2026-07-21 15:23 | 3.94 | 2.01 | 1.93 | **49 %** |
| 2026-07-21 15:08 | 3.91 | 1.94 | 1.97 | **50 %** |
| 2026-07-10 15:38 | 3.80 | 1.80 | 2.00 | **53 %** |
| 2026-07-09 15:08 | 3.68 | 1.60 | 2.07 | **56 %** |
| 2026-07-13 15:08 | 3.49 | 1.61 | 1.88 | **54 %** |
| 2026-07-12 15:08 | 3.41 | 1.50 | 1.91 | **56 %** |

House load in every one of these is a modest 1.5–2.3 kW. This confirms the
2026-07-10 hypothesis ("spikes stacking ON TOP of charging") with billed data,
and it means **the charge-stop is the dominant lever**, not the discharge.

### 4.2 Threshold sweep

Release threshold (0.8 / 1.0 / 1.5) and a 15-min response cap made **no
material difference** — trigger dominates.

| Trigger | Peak after | Δpeak | Capacity €/yr | Events/day | Discharge min/day |
|---|---|---|---|---|---|
| 3.0 | 3.94 | 0.50 | €24 | 0.4 | 9 |
| 2.5 *(old)* | 3.68 | 0.76 | €36 | 1.2 | 19 |
| **2.0 (chosen)** | **3.41** | **1.02** | **€49** | **3.4** | **31** |
| 1.5 | 3.00 | 1.44 | €69 | 8.2 | 49 |

## 5. Why 2.0 and not 1.5

Lowest trigger ≠ most money. Two effects sit outside the capacity model and
both cut against aggression:

1. **Arbitrage is the bigger pool.** Evening arbitrage runs ≈ €0.50+/evening
   ≈ **€180/yr**, well above the €69/yr capacity ceiling. Every trigger stops
   charging; at trigger 1.5 that is ~49 min/day of interrupted charging
   (≈1.8 kWh/day deferred). If the cheap window has no slack to recharge, that
   can eat €60+/yr — roughly cancelling the capacity gain. At 2.0 the exposure
   is ~31 min/day.
2. **There is a 2.5 kW billing floor.** Reducing the peak below 2.5 kW earns
   nothing. Trigger 1.5 only reaches 3.00 kW, so the remaining headroom is thin
   relative to its cost.

2.0 captures **71 % of the maximum capacity gain at ~40 % of the churn**.

**Model limits (stated honestly):** the arbitrage-loss figure is a
back-of-envelope bound, not a simulation — deferred charging is only *lost* if
the cheap window lacks slack, which was not modelled. Battery cycle wear is not
priced. The window is 14 summer days with no heating season. The discharge
offset is bounded by the AC-out circuit, so the responder cannot offset a spike
on a non-critical circuit at all — only the charge-stop helps there.

## 6. What shipped

`landingzones/jupiter-tervuren/values.yaml`:

```yaml
spike_responder:
  mode: active        # was: observe
  trigger_kw: 2.0     # was: 2.5
  release_kw: 1.0
  trigger_consecutive: 2
  release_consecutive: 3
  cooldown_seconds: 120
```

Safety envelope is unchanged and still in force: the responder is an override
consulted inside `LiveController.apply` (so every re-apply path converges),
guard-hold always wins, the SoC floor is absolute, samples are staleness-aware,
and release restores the *current plan's intent* rather than a blind IDLE.

## 7. What to watch

- `jupiter_lar_spike_responses_total` should now become non-zero (it was absent
  in observe). Expect ≈ **3.4 events/day, ~31 min/day discharging**.
- `jupiter_lar_spike_cooldown_suppressed_total` — if suppressions dominate
  responses, the signal is oscillating around 2.0 and the release/cooldown want
  a second look.
- Peak quarter-hour should trend toward ~3.4 kW; the Fluvius billed peak
  (`sensor.fluvius_meter_1sag1100121989_peak_power`) is the ground truth.
- Evening savings (`jupiter_savings_today_eur`) must **not** regress — that is
  the arbitrage pool this trades against, and the reason 1.5 was rejected.

**Rollback:** set `mode: observe` in the same file and deploy; the responder
stops commanding immediately (byte-identical planning when not active).

## 8. Follow-up worth more than this card

Since ~50 % of every peak quarter-hour is battery charging, the **bigger and
cheaper lever is planner-side**: shaping *when and how hard* the battery charges
so it stops stacking on house load, instead of reacting after the fact. That
costs no battery wear and no plan disruption. See ADR-0012 (capacity-tariff peak
shaving) / the dispatch `CapacityTerm`. Filed as a separate card.

## 9. Reproducing

Data pull (Flux, via `kubectl -n influxdb exec influxdb-influxdb2-0 -- influx query`):

```flux
from(bucket: "homeassistant")
  |> range(start: -14d)
  |> filter(fn: (r) => r._measurement == "W" and r._field == "value")
  |> filter(fn: (r) =>
       r.entity_id == "utility_room_home_energy_meter_electric_consumption_w" or
       r.entity_id == "buzzbrick_ap3002532000565690_grid_input_power" or
       r.entity_id == "buzzbrick_ap3002532000565690_alternating_current_out_power")
  |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
  |> keep(columns: ["_time","_value","entity_id"])
```

Analysis script: [`.scripts/177-spike-threshold-sweep.py`](../../.scripts/177-spike-threshold-sweep.py)
(reads the CSV above; prints the peak-composition table and the threshold sweep).
Run: `python3 .scripts/177-spike-threshold-sweep.py <csv>` — no third-party deps.
