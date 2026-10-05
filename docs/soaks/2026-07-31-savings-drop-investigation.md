# Savings-drop investigation — jupiter-lar tervuren, the 2026-07-30 flip

- **Date:** 2026-07-31 (data as of 2026-07-31T14:30Z)
- **Author:** Clio (soak & observation-report agent)
- **Trigger:** owner report — battery "charging during expensive hours", savings
  diminished. Candidate cause: the 2026-07-29/30 release (#264/#266): forecast
  trainer flipped to jupiter unions (`whole_home_union_jupiter` +
  `critical_load_union_jupiter` at tervuren), zeus decommissioned (scaled to 0),
  lar → v0.18.0 (interlock decommission mode).
- **Sources:** InfluxDB `zeus` bucket (`influx query`, read-only, in
  `influxdb-influxdb2-0`) for banked savings / price / forecast / realized load;
  Prometheus (ns `observability`, 15 d retention — covers the whole window) for
  the savings-source flag and gross charge/discharge counters; jupiter-lar
  container logs (ns `jupiter-tervuren`) for the plan trace. All queries in
  Appendix A. Cross-references the #226 charge/discharge-vs-price-band panel
  (savings-economics dashboard, gitops commit `b4f04e9`).

---

## 1. Verdict

**BROKEN, but not for the reason first assumed — and NOT certifiable yet on
1.5 post-flip days.** The 07-30 collapse (€1.58 → €0.10) is **both** a genuinely
narrower market **and** a real plan-instability regression that appeared exactly
on the first full post-flip day. It is **not** "mostly market, no action" (a):
on 07-30 the lar churned ~3.2 full battery cycles (41.2 kWh throughput, 33 %
of it same-hour charge+discharge) at break-even prices, with the plan objective
oscillating €2 ↔ €25 between adjacent 15-minute cycles and charging ~11 kWh into
the evening price peak. That churn is a plan pathology a narrow spread alone does
not justify — an oracle on the very same day/volume nets **+€2.33**; the lar
netted **≈ €0** on arbitrage. The forecast that drives the plan is
`service:critical_load`, whose training source was flipped to the jupiter union
on the **SOAK-GATED** `critical_load_union_jupiter` flag **without the required
overlap soak** — the single most likely driver.

**This is not "insufficient data → shrug": the regression is visibly present on
07-30.** What is insufficient is the evidence to declare it *persistent* vs. a
first-day-after-flip transient: 07-31 (partial) is calmer (no cost>€10, no
simultaneous charge+discharge) but still low-savings and still churning
direction. And the flip is **confounded** with the lar 0.18.0 roll (same
release), which this data cannot fully exclude.

**Recommendation in one line:** treat as a live regression — run the skipped
critical_load overlap soak now, add a churn/plan-instability guard, and re-judge
after **≥3 clean days that include at least one WIDE-spread day** (the decisive
test: does the lar still churn when real arbitrage is on the table?). See §5.

---

## 2. The window and its contamination map

Analysis window: **2026-07-23 00:00 → 2026-07-31 14:30 Europe/Brussels**
(CEST = UTC+2). All "days" below are Brussels-local.

**Date-label convention (verified, load-bearing).** `jupiter_daily_savings` in
InfluxDB is stamped at **00:00 local (day-start)** and updated through the day.
The latest point, `_time = 2026-07-30T22:00:00Z` (= 07-31 00:00 local) reads
**€0.1628**, which equals the live `jupiter_savings_today_eur` gauge
(**0.1634** at read time) — i.e. that point **is today (07-31) in progress**, not
07-30. Every banked figure below is therefore attributed to the local day whose
**start** the point stamps. This reproduces the owner's dates exactly.

| # | Interval | Event | Effect on data |
|---|---|---|---|
| C1 | 2026-07-29 21:57Z (merge #265) | **Forecast union flip + lar 0.18.0** deployed to master (Argo). `whole_home_union_jupiter` + `critical_load_union_jupiter` true; lar 0.17.0→0.18.0. Effective at **07-30 00:00 local**. | first FULL post-flip day = **07-30**. Flip and lar-roll are **confounded** (same release). |
| C2 | 2026-07-29 22:22Z (merge #267) | **zeus scaled to 0** (#169). `zeus_state`/`zeus_savings`/`zeus_load_history` stop being written. | `zeus_*` series **ABSENT** from ~07-30 00:00 local (confirmed). The forecast union now = frozen zeus tail ∪ live jupiter tail. |
| C3 | 2026-07-30 00:02 local | lar pod `jupiter-cell-594b95974d-w6cxz` (0.18.0) started, **0 restarts since**. | plan logs exist only from here — **no pre-flip plan trace is available** (old pod gone). Pre/post comparison rests on the persistent Prometheus counters, not logs. |

**Ruled-out confound (important):** the #164-style savings *wedge* is NOT in play.
`jupiter_reporting_savings_source{source="independent"}` = **1.0 for 769/769
samples** across 07-28→now (`insufficient_history` = 0 throughout). The savings
figures are computed on the healthy independent path — **the low savings are real
economics, not a measurement artifact** of zeus's `zeus_state` disappearing.

---

## 3. The numbers

### 3.1 Price spread vs banked savings (the market-vs-regression test)

Hourly day-ahead import price from `jupiter_state.import_price_eur_per_kwh`
(hourly mean = the hour's price; ENTSO-E day-ahead is a step function).
Banked savings from `jupiter_daily_savings.eur`.

| Local day | p10 | p90 | **spread p90−p10** | median | **banked €** | **€ / spread** | notes |
|---|---|---|---|---|---|---|---|
| 07-23 | 0.023 | 0.193 | 0.170 | 0.146 | 0.833 | 4.9 | |
| 07-24 | 0.056 | 0.201 | 0.145 | 0.160 | 0.712 | 4.9 | |
| 07-25 | −0.003 | 0.178 | 0.181 | 0.132 | **0.018** | **0.1** | pre-flip poor day |
| 07-26 | −0.000 | 0.166 | 0.167 | 0.119 | **−0.090** | **−0.5** | pre-flip poor day |
| 07-27 | 0.000 | 0.176 | 0.176 | 0.074 | 1.021 | 5.8 | |
| 07-28 | 0.003 | 0.204 | 0.201 | 0.155 | 1.571 | 7.8 | |
| 07-29 | 0.004 | 0.227 | 0.223 | 0.149 | 1.577 | 7.1 | last pre-flip day |
| **07-30** | **0.099** | **0.196** | **0.097** | 0.146 | **0.103** | **1.1** | **first full post-flip day** |
| 07-31* | 0.096 | 0.181 | 0.085 | 0.157 | 0.163* | 1.9* | partial (→14:30) |

`*` 07-31 in progress. All prices EUR/kWh; savings EUR.

**Reading.** The spread genuinely collapsed: 0.223 (07-29) → 0.097 (07-30), less
than half. Narrower spread ⇒ structurally less arbitrage — **that part is
market**. But **savings-per-unit-spread also collapsed**, 7.1 → 1.1. `€/spread`
is not a physical constant, but the good pre-flip days cluster at 4.9–7.8; had
07-30 merely tracked the *lower* end (≈5), its 0.097 spread would still bank
≈ €0.49, not €0.10. So roughly half the drop is the narrow market and half is
lost efficiency. **Caveat (honesty):** low-savings days pre-exist the flip
(07-25 €0.02, 07-26 −€0.09) at *decent* spreads — low savings are not unique to
the flip. But their failure mode is different (see §3.3).

### 3.2 Forecast quality across the flip (critical_load drives the plan)

`critical_load` forecast (`jupiter_forecast{target=critical_load}`) vs realized
critical-circuit energy (`jupiter_load_history.kwh + .ac_kwh`; `ac_kwh` ≈ 0.0004,
negligible). `jupiter_load_history` was written "dark" pre-flip, so it is a
consistent ground truth across the boundary. Bias = forecast − realized (kWh/h).

| Local day | n | fc mean | realized mean | **bias** | MAE | MAPE% |
|---|---|---|---|---|---|---|
| 07-23 | 24 | 0.779 | 0.618 | +0.161 | 0.274 | 58 |
| 07-24 | 24 | 0.707 | 0.942 | −0.235 | 0.526 | 47 |
| 07-25 | 24 | 0.697 | 0.853 | −0.156 | 0.266 | 30 |
| 07-26 | 24 | 0.615 | 0.662 | −0.047 | 0.247 | 38 |
| 07-27 | 24 | 0.621 | 0.723 | −0.103 | 0.175 | 25 |
| 07-28 | 24 | 0.702 | 0.923 | −0.221 | 0.539 | 59 |
| 07-29 | 24 | 0.957 | 1.087 | −0.130 | 0.733 | 76 |
| **07-30** | 24 | 0.783 | 1.032 | **−0.249** | 0.596 | 69 |
| 07-31* | 15 | 0.519 | 0.951 | **−0.432** | 0.564 | 47 |

**Reading — and a correction to the working hypothesis.** The critical_load
forecast **UNDER-predicts** (negative bias) on **both** sides of the flip, not
over-predicts. The owner's "over-predicting → over-charge" mechanism is **not**
what the data shows. Post-flip bias worsens modestly (−0.13 avg pre-flip →
−0.25 / −0.43) and MAE rises to 0.60/0.56, but the worst *single* pre-flip day
(07-29, MAE 0.733) exceeds 07-30 — so on aggregate error alone the flip is **not
a clean regression**. The forecast has been chronically noisy the whole window
(MAPE 25–76 %). The regression signal is **not the aggregate MAE** — it is the
*instability* this noisy forecast now injects into the plan (§3.4). whole_home
(vs integrated `grid_power_w`) tells the same story: small biases pre-flip,
drifting negative post-flip (07-30 −0.14, 07-31 −0.42).

> Methodology caveat: the operative forecast used here is the last-write-per-hour
> (≈ short lead). The plan consumes the multi-hour horizon; the plan-cost trace
> in §3.4 is the more direct instability signal.

### 3.3 Dispatch: throughput and same-hour churn (the attribution test)

Gross charge/discharge per hour from the daily counters
`jupiter_savings_charged_today_kwh` / `_discharged_today_kwh` (hourly deltas).
"Churn" = Σ min(charge_h, discharge_h) — energy both charged **and** discharged
in the *same hour* = pure round-trip loss.

| Local day | throughput kWh | churn kWh | churn % | pattern |
|---|---|---|---|---|
| 07-24 | 15.5 | 1.55 | 10 | normal |
| 07-25 | 5.9 | 1.62 | 28 | poor day — **do-little** |
| 07-26 | 9.4 | 2.03 | 22 | poor day — **do-little** |
| 07-27 | 22.5 | 2.60 | 12 | good |
| 07-28 | 36.0 | 5.08 | 14 | good |
| 07-29 | 25.2 | 2.78 | 11 | good |
| **07-30** | **41.2** | **13.59** | **33** | **churn-a-lot (outlier)** |
| 07-31* | 8.8 | 0.40 | 5 | partial (barely discharged yet) |

**This is the key attribution result.** 07-30 is a regime change on **both**
axes: highest throughput ever (41.2 kWh ≈ 3.2 full cycles on a 13 kWh pack) and
highest churn (13.6 kWh, 33 %). The pre-flip **poor** days (07-25/26) failed the
*opposite* way — they moved almost nothing (6–9 kWh) at thin spreads. Neither the
good nor the bad pre-flip days resemble 07-30. **A new failure mode appeared
exactly on the first full post-flip day.** Cross-references the #226 panel, which
visualizes the same charge-in-expensive / discharge-in-cheap slots.

### 3.4 The mechanism — plan oscillation (lar plan trace, 07-30 evening)

Consecutive 15-minute plan cycles, 07-30 evening (`jupiter_lar.plan … slot0`):

```
17:00 chg=1.258 dis=0.000 cost=24.92     <- objective spikes 10x
17:15 chg=1.258 dis=0.000 cost=21.81
17:30 chg=0.000 dis=0.942 cost=2.16      <- flips to discharge, cost back to normal
18:00 chg=2.200 dis=3.585 cost=2.20      <- SIMULTANEOUS charge AND discharge
18:30 chg=0.815 dis=0.000 cost=18.13     <- spikes again
18:45 chg=2.200 dis=3.585 cost=2.29
19:00 chg=0.000 dis=0.993 cost=2.11      <- flips back
```

`forecast_src=service:critical_load` on every line. A plan **objective swinging
€2 ↔ €25** between adjacent refreshes, and **slot0 flipping charge ↔ discharge**
(even emitting simultaneous charge+discharge), is the optimizer oscillating
because its critical_load input is unstable between reads. Per-day plan stats
(logs exist only post-flip):

| Local day | cycles | cost mean | **cost max** | cycles cost>€10 | simultaneous c&d | dir-flips |
|---|---|---|---|---|---|---|
| 07-30 | 96 | 3.45 | **24.92** | 5 | 3 | 8 |
| 07-31* | 65 | 3.07 | 7.67 | 0 | 0 | 6 |

The acute instability (€25 cost spikes, simultaneous charge+discharge) is
concentrated on **07-30** and has not recurred on 07-31 so far — consistent with
a **first-day-after-flip transient** (the trainer's first bakes on the jupiter
union were 07-30) that is partly settling, though 07-31 is still low-savings and
still flips direction (6×).

### 3.5 What the churn cost — oracle comparison

Same-day oracle: place the *actual* day's charge volume in the cheapest hours and
discharge volume in the dearest (caps = observed hourly max).

| Local day | charge @avg | discharge @avg | actual net | oracle net | **miss** |
|---|---|---|---|---|---|
| 07-29 | 13.6 kWh @0.082 | 11.5 kWh @0.198 | +1.16 | +2.49 | 1.32 |
| **07-30** | 21.4 kWh @**0.151** | 19.8 kWh @**0.162** | **−0.03** | +2.33 | **2.36** |
| 07-31* | 7.3 kWh @0.124 | 1.5 kWh @0.175 | −0.63 | −0.49 | 0.14 |

On 07-29 the lar charged cheap (€0.082) and discharged dear (€0.198) — clean
arbitrage. On 07-30 it charged and discharged at **essentially the same price**
(€0.151 vs €0.162); after round-trip losses the arbitrage net is **negative**.
The €0.10 banked that day comes from baseline peak-shaving/self-consumption
credit, **not** arbitrage. The oracle shows ~€2.3 was on the table even at the
narrow spread — the plan captured ~none of it and added churn losses on top.
(The oracle overstates a *smart* target — a good planner would not cycle 21 kWh
on a 0.10 spread at all — but it cleanly demonstrates the placement was
pathological.)

The owner's specific example (evening charge at the price peak) reproduces:
07-30 hh21–22 charged while price was €0.205–0.208 (the daily max, price
position 96–100 %), immediately after discharging into hh20 (€0.183). Charging at
the day's most expensive hour with no higher price ahead is value-destroying.

---

## 4. Incidents in the window

- **Savings collapse 07-30 (this report).** €1.58 (07-29) → €0.10 (07-30) →
  €0.16 (07-31 partial). Root cause: narrow market **plus** a plan-instability
  regression coincident with release #264/#266 (union flip + lar 0.18.0). No
  Trello card filed yet — recommend one (§5).
- **zeus decommission (#169), 07-29 22:22Z.** Expected; `zeus_*` series absent as
  designed. Confirmed NOT to have wedged the savings path (§2).
- **No alert fired.** There is no rule on battery over-cycling, same-hour churn,
  or plan-cost instability — the 07-30 pathology was invisible to alerting
  (monitoring gap, §5.4).

---

## 5. Recommendation

**Treat as a live regression, not market noise.** Do not wait this out silently.

### 5.1 Run the soak that was skipped
`critical_load_union_jupiter` was **SOAK-GATED** and flipped ~1 week early
without the required per-hour agreement check between `jupiter_load_history` and
`zeus_load_history` (per the forecast service's own #203 note). Run that overlap
soak **now** against the retained zeus tail (both series are in the bucket over
the pre-07-30 overlap): if jupiter's per-control-cycle integration is noisier or
biased vs zeus's HA-recorder integration, that is the forecast-instability root.

### 5.2 The decisive re-judgement test
Judge persistence after **≥3 clean days that include at least one WIDE-spread
day** (spread ≥ ~0.18, like 07-28/29). The critical question a thin-spread day
*cannot* answer: **does the lar still churn when real arbitrage is available?**
If a wide-spread day banks ≥€1 with churn back under ~15 %, the 07-30 event was a
first-day-after-flip transient (market did the rest). If a wide-spread day still
churns, the union forecast is a persistent regression.

### 5.3 Concrete fixes (zeus-only revert is impossible — zeus is dead)
- **Forecast stability:** limit bake-to-bake change / smooth the critical_load
  training corpus, or re-weight the union toward the (frozen, quieter) zeus tail
  vs the denser jupiter tail.
- **Controller-side churn guard (independent of forecast):** a minimum-dwell /
  hysteresis so the plan cannot reverse charge↔discharge within N cycles, and
  never emits simultaneous charge+discharge. This caps the damage regardless of
  forecast quality and is the fastest mitigation.

### 5.4 Close the monitoring gap
Add alerts on (a) daily throughput > ~2 full cycles, (b) same-hour churn
fraction > ~20 %, (c) plan-cost inter-cycle volatility (e.g. max/median > 5×).
Any of these would have caught 07-30 on the day.

### 5.5 What would change the verdict
A wide-spread clean day banking ≥€1 with low churn → downgrade to "market, plus a
settled transient" (no action beyond monitoring). Another 07-30-style churn day
(throughput > 2 cycles, churn > 20 %, cost spikes) → confirmed persistent
regression → engineering fix required before the next owner-facing savings claim.

---

## Appendix A — reproduction queries

**InfluxDB** (`kubectl -n influxdb exec influxdb-influxdb2-0 -- influx query …`,
org `zeus`, bucket `zeus`, read-only). Window start `2026-07-22T22:00:00Z`.

```flux
// banked daily savings (day-start stamped; latest point == live today gauge)
from(bucket:"zeus") |> range(start:-10d)
 |> filter(fn:(r)=>r._measurement=="jupiter_daily_savings") |> sort(columns:["_time"])

// hourly import price (spread per day)
from(bucket:"zeus") |> range(start:START)
 |> filter(fn:(r)=>r._measurement=="jupiter_state" and r._field=="import_price_eur_per_kwh" and r.site_id=="tervuren")
 |> aggregateWindow(every:1h, fn:mean, createEmpty:false)

// critical_load forecast vs realized (bias/MAE)
from(bucket:"zeus") |> range(start:START)
 |> filter(fn:(r)=>r._measurement=="jupiter_forecast" and r._field=="load_kwh" and r.target=="critical_load" and r.site_id=="tervuren")
from(bucket:"zeus") |> range(start:START)
 |> filter(fn:(r)=>r._measurement=="jupiter_load_history" and (r._field=="kwh" or r._field=="ac_kwh") and r.site_id=="tervuren")

// whole_home realized proxy = integrated grid power
from(bucket:"zeus") |> range(start:START)
 |> filter(fn:(r)=>r._measurement=="jupiter_state" and r._field=="grid_power_w" and r.site_id=="tervuren")
 |> aggregateWindow(every:1h, fn:mean, createEmpty:false)   // /1000 -> kWh/h (net import; negatives=export)

// dispatch direction cross-check
... r._field=="energy_stored_kwh" | "soc_pct" | "ac_power_w"   // ac_power_w is UNSIGNED magnitude
```

**Prometheus** (`kubectl -n observability port-forward
svc/kube-prometheus-stack-prometheus 9090`, retention 15 d):

```promql
// savings NOT wedged: 1.0 for 769/769 samples over 07-28..now
jupiter_reporting_savings_source{source="independent"}      // step 300s == 1.0
jupiter_reporting_savings_source{source="insufficient_history"} // == 0.0

// zeus decommission (all ABSENT)
zeus_savings_today_eur ; zeus_state ; zeus_realized_load_kwh ; zeus_load_kwh

// gross per-hour charge/discharge (hourly deltas of daily counters) -> churn
jupiter_savings_charged_today_kwh                            // step 300s
jupiter_savings_discharged_today_kwh

// live savings gauges (reconcile day-label convention)
jupiter_savings_today_eur ; jupiter_savings_baseline_eur ; jupiter_savings_actual_eur
```

**jupiter-lar plan trace** (`kubectl -n jupiter-tervuren logs deploy/jupiter-cell
--timestamps`, pod started 07-30 00:02 local, 0 restarts):

```
grep 'jupiter_lar.plan .* slot0'    // charge=/discharge=/cost=/forecast_src=service:critical_load
```

## Appendix B — limits of this report

1. **Only ~1.5 post-flip days** (07-30 full, 07-31 partial). Sufficient to
   *observe* the regression on 07-30; insufficient to prove persistence.
2. **Flip is confounded with lar 0.18.0** (same release #264). The interlock
   change is documented economics-neutral, so the critical_load union is the
   more likely driver, but this data cannot fully exclude the lar roll.
3. **No pre-flip plan trace** (old lar pod gone) — pre/post attribution rests on
   the persistent Prometheus counters (§3.3), not the plan logs (§3.4).
4. Forecast bias uses a short-lead operative forecast; the plan uses the full
   horizon. The plan-cost trace (§3.4) is the more direct instability evidence.
