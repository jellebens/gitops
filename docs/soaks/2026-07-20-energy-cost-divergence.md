# Energy & cost tile divergence — zeus vs jupiter (tervuren)

- **Date:** 2026-07-20 (data through 2026-07-20T~11:00Z)
- **Author:** Clio (soak & observation-report agent)
- **Trigger:** kiosk migration #198 (argus) found the **Charged / Discharged**
  (`energy_charged` / `energy_discharged`) and **Baseline cost / Actual cost**
  tiles diverge ~2× between `zeus_*` and `jupiter_*`, blocking their migration.
  Nobody knew whether that was definitional or a bug. This report answers it,
  while both controllers are still live (zeus decommissions ~2026-08-06, #169).
- **Sources:** Prometheus (kube-prometheus-stack, ns `observability`, 15d
  retention — covers the whole window), zeus repo (`zeus/main.py`,
  `zeus/reporter.py`), jupiter repo
  (`services/reporting/jupiter_reporting/{realized.py,savings.py,metrics.py}`).
  Every number is reproducible from the queries in Appendix A.

## 1. Verdict

**DEFINITIONAL difference, not an accounting bug — and the divergence is NOT a
clean 2×.** The two stacks run **byte-identical savings arithmetic** but feed it
**different input series by design**:

- **zeus** feeds **gross AC-port meters** — `grid_input_power` as "charge",
  `ac_output_power` as "discharge" — which include **continuous load
  pass-through** through the inverter (grid → unit → house load), not just
  battery activity.
- **jupiter** feeds **net battery flow** reconstructed from `energy_stored_kwh`
  (SoC) deltas — only what actually entered/left the cells.

The pass-through term sits in **both** the baseline leg (via `ac_output`) and
the actual leg (via `grid_input`), so it **cancels in `savings = baseline −
actual`** — which is why the #164 savings-parity cross-check is green (verified
again here: EOD savings agree within €0.007–€0.068 every day 07-14→07-19). It
does **not** cancel in the standalone component tiles, so `energy_charged`,
`energy_discharged`, `baseline_cost` and `actual_cost` each diverge.

**Which side is right for the tiles?** For the semantics those tiles claim —
*battery* energy charged/discharged, and the grid cost *attributable to the
battery* — **jupiter is the faithful measure; zeus is inflated by load
pass-through.** zeus's numbers are whole-unit AC-port throughput mislabeled as
battery energy/cost. (Caveat: jupiter's figures are *net-per-15-min-interval*, a
mild under-count of gross battery throughput — see §4 — so jupiter is a tight
lower bound on true battery kWh, still far closer to the tile's meaning than
zeus.)

**Consequence for #169:** there is **no hidden accounting bug** here. The
cross-check the soak existed to provide — savings parity — passed, and this
divergence is fully explained by the code. **It does not block zeus
decommission.** The blocked tiles **can** migrate to `jupiter_*` now; they will
roughly halve, and that is correct. This is dashboard/relabel work (argus), not
a jupiter-reporting or zeus code fix.

## 2. Window & contamination

- **Component-ratio window:** Brussels days **2026-07-14 → 2026-07-19** (the six
  clean days the #164 sign-off certified; EOD read at 21:55Z = 23:55 local).
  Intraday trajectory sampled on **2026-07-16** (a high-divergence day).
- **2026-07-20** is in progress; used only for the "@now" existence check, never
  for day statistics.
- **Excluded / not relevant:** the 07-08→07-10 reporting `insufficient_history`
  wedge and CNP outage (documented in `2026-07-11-savings-parity-soak.md`) are
  well before this window. The 07-15 lar roll to 0.13.2 was I/O-only and does
  not touch the reporting savings path. Reporting recomputes each component from
  its own persisted `jupiter_state` history, so release pod-rolls in the window
  do not reset the EOD accumulations. All six days read `savings_source =
  independent`.

## 3. The numbers

### 3.1 EOD component divergence (per Brussels day, 21:55Z)

zeus series carry no `site_id`; jupiter series are `site_id="tervuren"`.

| Day | Charged kWh (zeus / jup / ×) | Discharged kWh (zeus / jup / ×) | Baseline € (zeus / jup / ×) | Actual € (zeus / jup / ×) | Savings € (zeus / jup / \|Δ\|) |
|---|---|---|---|---|---|
| 07-14 | 14.24 / 8.58 / **1.66** | 13.44 / 7.60 / **1.77** | 1.967 / 1.245 / **1.58** | 1.688 / 0.976 / **1.73** | 0.379 / 0.391 / 0.012 |
| 07-15 | 21.18 / 8.71 / **2.43** | 21.77 / 10.19 / **2.14** | 3.426 / 1.828 / **1.87** | 2.853 / 1.068 / **2.67** | 0.495 / 0.563 / 0.068 |
| 07-16 | 24.74 / 9.57 / **2.59** | 21.70 / 8.64 / **2.51** | 3.732 / 1.848 / **2.02** | 3.359 / 1.213 / **2.77** | 0.810 / 0.769 / 0.042 |
| 07-17 | 18.60 / 8.19 / **2.27** | 12.51 / 4.62 / **2.71** | 1.762 / 0.764 / **2.31** | 2.323 / 0.980 / **2.37** | 0.251 / 0.260 / 0.009 |
| 07-18 | 14.43 / 9.71 / **1.49** | 11.94 / 7.53 / **1.59** | 1.095 / 1.099 / **1.00** | 0.155 / 0.155 / **1.00** | 1.138 / 1.118 / 0.020 |
| 07-19 | 17.15 / 9.85 / **1.74** | 14.59 / 8.39 / **1.74** | 1.105 / 1.103 / **1.00** | 0.095 / 0.016 / *(noise)* | 1.176 / 1.183 / 0.007 |

Read-off:

- **Not exactly 2×, not constant.** EOD ratios span **1.5×–2.8×** on energy,
  **1.0×–2.8×** on cost. **Same sign every day** (zeus ≥ jupiter). The "~2×" #198
  saw is just the coincidental day-average magnitude.
- **Savings agree** every day (|Δ| ≤ €0.07) — the divergence is confined to the
  components, exactly as the cancel-in-the-difference mechanism predicts.
- **Cost divergence is price-weighted, so even more variable than energy.** On
  07-18/07-19 the *cost* tiles nearly coincide (ratio 1.00) while the *energy*
  tiles still diverge ~1.7×: the extra pass-through kWh those days fell in
  near-zero-price overnight slots, adding energy but almost no euros. Cost =
  Σ(energy × price), so the pass-through inflates cost only when it coincides
  with non-trivial prices.

### 3.2 Intraday trajectory (2026-07-16, hourly, `max()` of the cumulative gauge)

The ratio is not just day-to-day — it swings **within** a day, and the shape
exposes the mechanism.

| Hour (UTC) | Charged z/j (×) | Discharged z/j (×) |
|---|---|---|
| 00:00 | 0.72 / 0.00 | 0.99 / 0.00 |
| 02:00 | 1.17 / 0.00 | 1.44 / 0.00 |
| 06:00 | 3.58 / 0.97 (3.7×) | 3.31 / 0.75 (4.4×) |
| 10:00 | 9.45 / 3.53 (2.7×) | 6.87 / 0.88 (**7.8×**) |
| 14:00 | 17.86 / 6.96 (2.6×) | 10.74 / 0.88 (**12.2×**) |
| 16:00 | 21.84 / 9.05 (2.4×) | 11.97 / 0.88 (**13.6×**) |
| 19:00 | 23.42 / 9.57 (2.5×) | 15.71 / 4.79 (3.3×) |
| 21:00 | 23.42 / 9.57 (2.5×) | 19.83 / 8.64 (2.3×) |

**The smoking gun (00:00–02:00Z):** jupiter's charged **and** discharged are
both **0.00** — the battery is net-flat overnight — while zeus simultaneously
accumulates **both** charged (0.72→1.17 kWh) **and** discharged (0.99→1.44 kWh).
Non-zero grid_input **and** ac_output with ~zero net battery change is, by
definition, **pure grid→load pass-through**. Through the day jupiter's
*discharged* stays pinned at ~0.88 kWh (battery holding, not discharging) while
zeus's `ac_output` climbs to 12 kWh serving house load — the discharged ratio
balloons to **13.6×**. Only in the evening (18:00→21:00Z), when the battery
actually discharges into the peak, does jupiter's discharged rise and the ratio
collapse back to ~2.3×.

## 4. Root cause — from the code

Both repos ship an **identical** `compute_arbitrage_savings`
(`zeus/reporter.py` ≡ `jupiter_reporting/savings.py`, golden-pinned). In
arbitrage mode:

```
baseline_cost (value) = Σ discharge_kwh[t] · price[t]     # grid import avoided
actual_cost   (cost)  = Σ charge_kwh[t]    · price[t]     # paid to charge
savings = value − cost + stored-energy credit
energy_charged/discharged = Σ charge_kwh / Σ discharge_kwh
```

The divergence is entirely in **what `charge_kwh` / `discharge_kwh` are**:

- **zeus** (`zeus/main.py::_todays_savings`, lines ~1394–1395):
  `charge = series_or_zeros(cfg.entities.grid_input_power)`,
  `discharge = series_or_zeros(cfg.entities.ac_output_power)` — the inverter's
  **AC-port power meters**, integrated to per-slot kWh. These carry **all** grid
  draw and **all** AC output, including load that passes straight through the
  unit without touching the cells.
- **jupiter** (`jupiter_reporting/realized.py::compute_realized_from_state`):
  per interval it takes the signed `energy_stored_kwh` (SoC) delta as the
  realized **net** battery flow and converts DC→AC via the round-trip
  efficiencies —
  `rise → charge_ac = ΔDC / eff_c`, `fall → discharge_ac = |ΔDC| · eff_d`.
  Only actual cell charge/discharge; pass-through is invisible to SoC, so it is
  excluded.

This is **deliberate and documented** — `realized.py`'s module docstring states
it plainly: *"zeus feeds GROSS AC port flows (grid_input_power / ac_output_power)
whose load pass-through cancels in the EUR but not in the reported kWh — so the
parity monitor now compares two genuinely independent numbers."* Card #163 chose
the net-SoC path precisely so jupiter's savings are independently sensed rather
than a re-read of zeus.

**Why savings cancel but components don't** — at the AC node,
`grid_input − ac_output = net AC into the battery`:
- pass-through-only slot: `grid_input = load = ac_output` → adds `load·price` to
  **both** baseline and actual → **cancels** in savings.
- charge slot: `grid_input = load + charge`, `ac_output = load` → nets to
  `−charge·price` (charging cost). Discharge slot: `ac_output = load`,
  `grid_input ≈ 0` → nets to `+discharge·price` (avoided import).

So the **difference** (savings) sees only genuine battery arbitrage and matches
jupiter; the **legs** (baseline, actual) and the **energy sums** each carry the
full pass-through and inflate.

**Is zeus "buggy"?** The arbitrage docstring says its inputs are *"the energy
that flowed into/out of the battery at the AC side"* — but `grid_input_power` /
`ac_output_power` are **whole-unit port** flows, not battery flows. So zeus's
component tiles are a **latent mislabel**: correct for savings (invariant to it),
wrong as standalone "battery energy/cost". It is not worth fixing in zeus (2
weeks from decommission); jupiter already sources the correct quantity.

**jupiter's one honest limitation:** the SoC deltas are sampled at the 15-minute
`jupiter_state` cadence, so a charge-then-discharge *within* one interval nets
out and is under-counted. jupiter's throughput is therefore a **lower bound** on
gross battery kWh — but it is the right *semantic* quantity and the savings
parity confirms the pricing is faithful. Neither side reports true gross battery
throughput; if that specific quantity is ever wanted it is a new metric, not a
fix to either.

## 5. Recommendation

1. **Migrate the four blocked tiles to `jupiter_*` — they are the correct
   battery figures.** Charged → `jupiter_savings_charged_today_kwh`,
   Discharged → `jupiter_savings_discharged_today_kwh`, Baseline →
   `jupiter_savings_baseline_eur`, Actual → `jupiter_savings_actual_eur` (all
   `{site_id="tervuren"}`). Tiles live in `landingzones/zeus/dashboards/`:
   `battery-kiosk.json` (Charged/Discharged), `mission-control.json`
   (Charged/Discharged), `battery-optimizer.json` (all four). **Owner: argus**,
   under the #198/#165 kiosk-migration umbrella (or a small sub-card).
2. **No numeric transform can reconcile them — and none should.** The ratio is
   time-varying (1.5×–13.6×), so there is no constant to divide out; and
   reproducing zeus's inflated pass-through numbers is not the goal. Flag to the
   owner that **the migrated tiles will roughly halve** — this is the
   correction, not a regression. A one-line tile note ("net battery energy;
   excludes inverter load pass-through") is worth adding so the step-down is
   self-explaining on the kiosk.
3. **Do NOT open a jupiter-reporting or zeus code card.** The savings figure —
   the thing #164 signed off — is correct on both sides. The only defensible
   code change would be a *new* jupiter "gross AC-port throughput" metric, and
   only if the owner explicitly wants that quantity preserved past zeus
   decommission. Default recommendation: don't; net battery energy is the more
   useful tile.
4. **#169 (zeus decommission ~08-06) is unaffected.** This divergence is fully
   explained and carries no hidden accounting error, so it is not a reason to
   keep zeus alive. The *only* thing zeus uniquely provided here was the gross
   AC-port sensing (`grid_input_power` / `ac_output_power`); if anyone ever wants
   pass-through/whole-unit throughput history, capture those two HA series before
   08-06 — but nothing in savings needs it.

**What would change the verdict:** a day where savings parity *breaks* while the
components stay ~2× (would imply the pass-through no longer cancels — a real
model error); or evidence that jupiter's SoC-derived net flow mis-tracks battery
energy against a DC coulomb-counter (would move jupiter from "faithful" to
"also-approximate"). Neither is present in the window.

## Appendix A — reproduction queries

Prometheus (`kubectl -n observability port-forward
svc/kube-prometheus-stack-prometheus 9090:9090`), evaluated 2026-07-20 ~11:00Z.
Per-day EOD = instant query at `<day>T21:55:00Z`.

```
# existence / @now
zeus_energy_charged_today_kwh            zeus_energy_discharged_today_kwh
zeus_baseline_cost_today_eur             zeus_actual_cost_today_eur
zeus_savings_today_eur
jupiter_savings_charged_today_kwh        jupiter_savings_discharged_today_kwh
jupiter_savings_baseline_eur             jupiter_savings_actual_eur
jupiter_savings_today_eur

# EOD per Brussels day: instant query at time=<day>T21:55:00Z for each series above

# intraday trajectory (mechanism): query_range
#   start=2026-07-16T00:00:00Z end=2026-07-16T21:55:00Z step=3600
max(zeus_energy_charged_today_kwh)       max(jupiter_savings_charged_today_kwh)
max(zeus_energy_discharged_today_kwh)    max(jupiter_savings_discharged_today_kwh)
```

## Appendix B — code references

| Concern | zeus | jupiter |
|---|---|---|
| Savings arithmetic (identical, golden-pinned) | `zeus/reporter.py::compute_arbitrage_savings` | `jupiter_reporting/savings.py::compute_arbitrage_savings` |
| Charge/discharge **input series** | `zeus/main.py::_todays_savings` L1394-95 → `grid_input_power` / `ac_output_power` (AC-port meters) | `jupiter_reporting/realized.py::compute_realized_from_state` → `energy_stored_kwh` SoC deltas ÷/× efficiency |
| Component metric export | `zeus/metrics.py`: `zeus_{baseline_cost,actual_cost}_today_eur`, `zeus_energy_{charged,discharged}_today_kwh` (+ InfluxDB `zeus_savings`) | `jupiter_reporting/metrics.py`: `jupiter_savings_{baseline,actual}_eur`, `jupiter_savings_{charged,discharged}_today_kwh` |
| Design rationale (net vs gross, deliberate) | — | `jupiter_reporting/realized.py` module docstring |
