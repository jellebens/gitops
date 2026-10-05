# Critical-load overlap soak — `jupiter_load_history` vs `zeus_load_history` (tervuren)

- **Date:** 2026-10-05 (data through 2026-10-05T19:00Z)
- **Author:** Clio (soak & observation-report agent)
- **Trigger:** card [#228](https://trello.com/c/C9VHDZNI), part 1 — "run the SKIPPED
  critical_load overlap soak". The forecast trainer's `critical_load_union_jupiter`
  flag was documented as SOAK-GATED (jupiter `services/forecast/README.md`, "zeus →
  jupiter read-path cutover (card #202)") and was flipped on 2026-07-29 (gitops
  `d5e6c44`, committed 21:57Z) without the soak. The next day was the worst savings day on
  record; the 2026-07-31 investigation (gitops PR #272, never merged) named the
  un-soaked flip the "most likely driver". This report runs the soak, ten weeks late.
- **Sources (all READ-ONLY):** InfluxDB bucket `zeus` through Grafana's datasource
  proxy (`POST /api/ds/query`, datasource uid `influxdb`); jupiter repo
  (`packages/dispatch/jupiter_dispatch/energy.py`,
  `services/reporting/jupiter_reporting/load_history.py`,
  `services/forecast/jupiter_forecast/{train,history,models}.py`); zeus repo
  (`zeus/main.py`, `zeus/ha_client.py`). Every number is reproducible from the Flux in
  Appendix A and the arithmetic in Appendix C.

## 1. Verdict

> **The union flip did not feed the trainer biased data. The soak gate would have
> been safe to take — but not for the reason the README assumed, and the two series
> are NOT interchangeable hour by hour.**
>
> | Question | Verdict | Headline |
> |---|---|---|
> | 1. Per-hour agreement | **bias PASS, per-hour tolerance FAIL** | 217 h compared, 0 missing/duplicated. Bias **+0.9 %** (+1.1 % on the 173 non-frozen hours; 95 % CI −2.7…+4.9 %). MAE **11.9 %** (14.7 % non-frozen) of mean hourly load, r = 0.885. |
> | 2. Noisier / structured? | **Same noise class; one structural offset** | Neither side integrates: both store ONE instantaneous watt reading per hour. zeus reads the HA state at T:00:00; jupiter's value is the lar's reading from **~15 min before the hour**. SD ratio 1.05. |
> | 3. `ac_kwh` | **PASS** | 215 of 217 h identical (17 of 19 A/C-on hours to 4 decimals); the 2 mismatches are on/off edges shifted one hour by the same 15-min offset. Sum +0.5 %. |
> | 4. Whole-home same signal? | **CONFIRMED** | Hourly mean 1021.4 W vs 1021.1 W (+0.03 %), r = 0.986; where zeus has only its 4 quarter-hour samples MAE is 0.56 %. jupiter stores the same readings zeus did. |
> | 5. Seam and holes | **Seam is 2026-07-20T21:00Z, not the flip date. The union has two holes and ~10 % fabricated hours.** | Missing 176 h (08-20T14 → 08-27T21Z) and 17 h (09-29T17 → 09-30T09Z); 197 flat-lined / carried / placeholder hours. `grid_power_w` hole confirmed: **2026-08-19T14:14:34Z → 08-26T20:23:52Z**. |
> | 6a. #228 root cause? | **NO** (not "cannot tell") | Replaying the 07-30 training window both ways moves the baseline forecast for 07-30 by **−1.4 %** (−0.26 kWh/day); (weekday,hour) bucket means move 0.021 kWh on average — a third of what the window's own weekly roll does (0.066 kWh). |
> | 6b. 90-day window safe today? | **NO for both targets** | `critical_load` is clean only from **2026-09-30T10:00Z**; `whole_home` from **2026-08-26T21:00Z** (so its 30-day window is clean, its 90-day window is not). |
>
> **Gate:** #228's "biased jupiter-side integration" hypothesis can be closed. The
> forecaster work must NOT widen `history_days` to 90 until the trainer has a
> gap/flat-line guard (§8).

## 2. The window and its contamination

| | Start (UTC) | End (UTC) | Hours |
|---|---|---|---|
| `zeus_load_history.kwh` (untagged, then `site_id=tervuren`) | 2026-06-23T20:00 | 2026-07-29T21:00 | 866 unique, contiguous |
| `jupiter_load_history.kwh` | 2026-07-20T21:00 | 2026-10-05T18:00 | 1653 present of 1846 |
| **Critical-load overlap (this soak)** | **2026-07-20T21:00** | **2026-07-29T21:00** | **217, all present on both sides** |
| `zeus_state.grid_power_w` | 2026-06-28T18:15:26 | 2026-07-29T22:22:33 | — |
| `jupiter_state.grid_power_w` (continuous writer) | 2026-07-20T20:26:33 | ongoing | — |
| Whole-home overlap | 2026-07-20T21:00 | 2026-07-29T22:00 | 216 full hours |

Known contamination inside the overlap, and how it was handled:

- **Sensor freeze, 2026-07-24T20:00Z → 07-26T15:00Z (44 h).** Both series read exactly
  0.635 kWh for 44 consecutive hours (jupiter 45: its exit lags one hour). The
  underlying `jupiter_state.house_load_w` has zero spread throughout (frozen Bluetti
  telemetry; the #211 stale-telemetry failsafe shipped the evening it ended). These
  hours agree trivially and are wrong on both sides — the A/C plug shows ~1.05 kWh/h
  on 07-25T17–21Z while "house load" sits at 0.635. Every statistic below is given
  **both** over all 217 hours and over the **173 "live" hours** with the 44 frozen
  hours removed. Verdicts use the live figures.
- **Deploys:** the lar was redeployed inside the window (0.14.0 → 0.16.4 → 0.16.5 on
  2026-07-26 evening per the gitops log, 0.18.0 at the flip). Neither hourly series
  has a gap as a result.
- **Partial first hour:** jupiter's first value (07-20T21:00Z) comes from samples that
  only begin at 20:26:33Z. Kept (one hour).
- **Not comparable at all:** an earlier stray chunk of `jupiter_state.grid_power_w`
  (2026-07-06T21:22 → 07-07T14:09Z, ~1000 samples) predates the #200 writer; not
  analysed.

The overlap is **9 days, mid-summer, one site**. Two of the nine days are frozen. See
§7 for what that cannot support.

## 3. Method and thresholds

**What the two writers actually do** (read from the code before any data was pulled):

- zeus: `history_to_series` (LOCF onto an hourly grid) → `power_history_to_energy`.
  The value stored at hour T is the HA-recorder state of the house-load sensor **in
  effect at T:00:00**, in W, × 1 h.
- jupiter: `power_samples_to_hourly_kwh` — the same function, ported — over
  `jupiter_state.house_load_w`. The value stored at hour T is the **last banked sample
  at or before T:00:00**, × 1 h.

So both "integrators" pick **one instantaneous reading per hour**. Neither is an
integral, and "sampling density" does not enter the result the way the README
expected.

**Thresholds**, fixed after reading that code and the series extents and **before any
hourly value was pulled**:

| # | Criterion | Pass | Why this size |
|---|---|---|---|
| T1 | Completeness | every overlap hour present exactly once on both sides | a missing hour silently changes a 4-sample bucket |
| T2 | Aggregate bias `(Σj − Σz)/Σz` | ≤ 2 % pass · 2–5 % marginal · > 5 % fail | bias does not average out: it lands 1:1 in every bucket mean and in the kWh the LP plans to cover. 2 % of ~16 kWh/day is 0.3 kWh/day (a few euro-cents at any realistic spread); 5 % starts to be a visible change in scheduled charge |
| T3 | Hour-of-day structure | fewer than 3 hours where all-but-one day share a sign AND the mean difference exceeds 10 % of that hour's mean | with 7–9 days per hour, ~1–3 such hours arise by chance; a block of them is a phase or scaling error |
| T4 | Per-hour interchangeability | MAE ≤ 5 % of mean hourly load | the tolerance the README implies ("agree per hour") |
| T4b | Equivalence as a training target (if T4 fails) | RMSE(j − z) ≤ day-to-day SD within an hour-of-day, and SD(j)/SD(z) within 0.9–1.1 | the model averages ~4 samples per (weekday,hour) bucket; a swap that adds less scatter than drawing a different week, and no extra variance, cannot move the fit more than the calendar already does |
| T5 | Timing | cross-correlation peaks at lag 0 | a one-hour label shift would be a real defect |
| T6 | Daily totals | each full day within ± 5 % | the day's total drives how much charge is scheduled |

Statistics: percentages are relative to the zeus mean over the compared hours;
hour-of-day and day splits use Europe/Brussels local time (the trainer's bucket
timezone); the bias CI is a 24-hour moving-block bootstrap (20 000 draws) because
hourly differences are autocorrelated.

## 4. The numbers

### 4.1 Q1 — per-hour agreement, `kwh`

| | All 217 h | Live 173 h (freeze removed) |
|---|---|---|
| Mean zeus / jupiter (kWh per hour) | 0.6742 / 0.6802 | 0.6842 / 0.6917 |
| Sum zeus / jupiter (kWh) | 146.31 / 147.61 | 118.37 / 119.67 |
| **Bias (j − z)** | **+0.0060 kWh, +0.89 %** | **+0.0075 kWh, +1.10 %** (95 % CI −2.7 … +4.9 %) |
| MAE | 0.0803 kWh, 11.9 % | 0.1007 kWh, **14.7 %** |
| RMSE | 0.1713 kWh, 25.4 % | 0.1919 kWh, 28.0 % |
| Pearson r | 0.885 | 0.885 |
| \|diff\| p50 / p95 / max (kWh) | 0.015 / 0.420 / 0.913 | 0.026 / 0.436 / 0.913 |
| SD zeus / jupiter (kWh) | 0.347 / 0.366 | 0.388 / 0.409 (ratio 1.05) |
| Sign of diff (+ / − / within 0.005) | 79 / 68 / 70 | 79 / 68 / 26 (sign test p = 0.41) |

Distribution of |diff| over the live hours: 78 h (45 %) ≤ 0.02 kWh · 51 h within
0.02–0.1 · 23 h within 0.1–0.3 · **21 h (12 %) > 0.3 kWh**. The load is bimodal in
the daytime (roughly 0.55 vs 1.05 kW — an appliance of ~500 W cycling), so two point
samples either agree to a few watts or differ by the whole appliance.

Missing / duplicated / one-sided hours in the overlap: **none** (217 expected, 217 on
each side). The only duplicate anywhere is 2026-07-04T19:00Z, present once untagged
and once tagged in `zeus_load_history` (both 0.709); the trainer's tagged-wins dedup
handles it and it is outside the overlap.

**Scorecard (live hours)**

| # | Result | Verdict |
|---|---|---|
| T1 completeness | 217 / 217, no duplicates | PASS |
| T2 bias | +1.10 % (all hours +0.89 %; +1.86 % if the one freeze-exit hour is also dropped) | PASS on the point estimate — 7 live days cannot exclude ± 5 %, they do exclude more |
| T3 hour-of-day structure | 1 hour flagged (22 h local, +17 %, 6 of 7 days positive) | PASS |
| T4 per-hour MAE ≤ 5 % | 14.7 % | **FAIL** |
| T4b target equivalence | RMSE(j − z) 0.192 kWh vs within-hour-of-day SD 0.324 kWh; SD ratio 1.05 | PASS |
| T5 lag | r = 0.885 at lag 0 vs 0.675 (j against the previous zeus hour) and 0.549 (next) | PASS, with an asymmetry explained in §4.2 |
| T6 daily totals ± 5 % | 4 of 6 full live days outside (+8.6, −5.8, −6.5, +10.2, −1.4, +4.1 %) | **FAIL** — signs alternate, mean +1.5 % ± 2.9 % (SE) |

By Brussels day (live hours only; 07-25 is entirely frozen):

| Day | Live h | Σ zeus kWh | Σ jupiter kWh | Diff | MAE kWh | Max \|diff\| |
|---|---|---|---|---|---|---|
| 07-21 | 24 | 13.83 | 15.01 | +8.6 % | 0.127 | 0.543 |
| 07-22 | 24 | 12.64 | 11.91 | −5.8 % | 0.114 | 0.566 |
| 07-23 | 24 | 15.84 | 14.82 | −6.5 % | 0.179 | 0.913 |
| 07-24 | 22 | 16.47 | 17.04 | +3.5 % | 0.040 | 0.332 |
| 07-26 | 6 | 4.93 | 4.45 | −9.6 % | 0.213 | 0.877 |
| 07-27 | 24 | 15.74 | 17.35 | +10.2 % | 0.100 | 0.483 |
| 07-28 | 24 | 18.12 | 17.86 | −1.4 % | 0.043 | 0.331 |
| 07-29 | 24 | 19.77 | 20.59 | +4.1 % | 0.056 | 0.442 |

By Brussels hour-of-day (live hours, n = 7–8 days each; kWh per hour):

| Hour | zeus | jupiter | Bias | +/− | Hour | zeus | jupiter | Bias | +/− |
|---|---|---|---|---|---|---|---|---|---|
| 00 | 0.748 | 0.847 | +13.2 % | 5/1 | 12 | 0.548 | 0.643 | +17.3 % | 4/2 |
| 01 | 0.440 | 0.447 | +1.8 % | 3/3 | 13 | 0.652 | 0.755 | +15.7 % | 3/3 |
| 02 | 0.402 | 0.411 | +2.4 % | 4/1 | 14 | 0.752 | 0.600 | −20.2 % | 3/3 |
| 03 | 0.392 | 0.406 | +3.5 % | 5/1 | 15 | 0.725 | 0.693 | −4.5 % | 1/5 |
| 04 | 0.402 | 0.387 | −3.8 % | 3/3 | 16 | 0.806 | 0.813 | +0.8 % | 4/3 |
| 05 | 0.403 | 0.402 | −0.2 % | 2/3 | 17 | 0.667 | 0.704 | +5.5 % | 4/3 |
| 06 | 0.407 | 0.404 | −0.8 % | 1/4 | 18 | 1.013 | 0.919 | −9.3 % | 4/4 |
| 07 | 0.408 | 0.401 | −1.9 % | 1/3 | 19 | 0.842 | 0.816 | −3.1 % | 2/6 |
| 08 | 0.444 | 0.407 | −8.2 % | 2/3 | 20 | 1.047 | 1.143 | +9.1 % | 4/3 |
| 09 | 0.596 | 0.465 | −22.0 % | 1/2 | 21 | 1.108 | 1.110 | +0.2 % | 5/3 |
| 10 | 0.744 | 0.717 | −3.6 % | 3/3 | 22 | 1.042 | 1.222 | **+17.2 %** | 6/1 |
| 11 | 0.675 | 0.701 | +3.8 % | 4/2 | 23 | 0.940 | 0.974 | +3.7 % | 5/3 |

Night hours agree within 4 %; daytime hours scatter by ± 20 % with no run of one
sign. Seven days per hour cannot separate that scatter from a real phase effect at
the morning ramp (09 h, −22 %) — see §7.

### 4.2 Q2 — is jupiter noisier or biased in a structured way?

**Not noisier. Offset by a quarter of an hour.**

What a raw trace shows (2026-07-23, the largest disagreement in the window,
zeus 1.136 vs jupiter 0.223 at 07:00Z):

| Time (UTC) | `jupiter_state.house_load_w` | Note |
|---|---|---|
| 06:45:28 → 06:59:36 | 223 W, re-banked every ~60 s | the lar's 06:45 reading, repeated |
| **07:00:00** | — | zeus LOCF reads the HA state here: **1136 W** |
| 07:00:37 → 07:05:38 | 1133 W | the lar's 07:00 reading |

- `jupiter_state` is banked every ~60 s, but the **value only changes once per 15-min
  lar cycle**: over 92 h in July, 357 of 358 `house_load_w` value changes fall in
  minute 0 or 1 of a quarter-hour; over 96 h in October, 378 of 378. There are 4
  distinct readings per hour, not 60 — and not "~10 s control-cycle samples".
- LOCF at T:00:00 therefore always returns the reading taken at **(T−1):45**. The
  07:00 reading lands a few seconds too late and is used for nothing.
- zeus used the HA recorder, whose LOCF at T:00:00 is the state at T:00:00.

Consequences, all visible in the data:

| Evidence | Value |
|---|---|
| Cross-correlation asymmetry | corr(j[T], z[T−1]) = 0.675 vs corr(j[T], z[T+1]) = 0.549 — jupiter resembles the *earlier* zeus hour |
| Against the mean of the 4 readings in hour T | zeus r = 0.858, MAE 17.0 % · jupiter r = 0.819, MAE 20.4 % |
| Against the mean of the 4 readings in hour **T−1** | jupiter r = **0.901**, MAE 15.8 % · zeus r = 0.812 |
| A/C on/off edges | both `ac_kwh` mismatches are edges falling in the last quarter of an hour, shifted one hour (§4.3) |
| Freeze exit | 07-26T16:00Z: zeus already live (1.512), jupiter still frozen (0.635) |

Where the differences concentrate (live hours):

| Slice | n | MAE kWh | Share of total \|diff\| |
|---|---|---|---|
| Previous hour quiet (4 readings within SD < 30 W) | 70 | 0.048 | 19 % |
| Previous hour active (SD ≥ 30 W) | 103 | 0.137 | **81 %** |
| Night, 00–07 local | 49 | 0.035 | — |
| Day, 07–24 local | 124 | 0.127 | — |

So the disagreement is point-sampling noise on a switching load, concentrated where
the load moved during the 15 minutes before the hour. There were no gaps in the
overlap, so "first/last hour of a gap" is only testable at the freeze exit above.

**A finding that matters more than the zeus/jupiter difference:** measured against the
4-reading hourly mean — the best estimate of the hour's energy the bucket holds — a
single point sample is off by RMSE **29 %** (zeus) to **34 %** (jupiter) of the mean
load. The training target is this noisy on *either* source, and has been since zeus.
It is unbiased (zeus +0.2 %, jupiter +1.3 % in total over the live hours), which is
why forecasts built on bucket means still work.

### 4.3 Q3 — `ac_kwh`

Overlap 2026-07-20T21:00Z → 07-29T21:00Z, 217 hours on both sides.

| | Value |
|---|---|
| Sum zeus / jupiter | 19.28 / 19.38 kWh (+0.54 %) |
| Hours within 0.0003 kWh | 215 of 217 |
| A/C-on hours (either side > 0.05 kWh) | 19, of which **17 identical to 4 decimals** |
| A/C-off hours | 198; mean 0.00048 kWh on both sides, max \|diff\| 0.0003 |
| Mismatches | 07-25T16:00Z zeus 0.9255 / jupiter 0.0004 (switch-on 15:45–16:00Z) · 07-28T22:00Z zeus 0.0005 / jupiter 1.0276 (switch-off 21:45–22:00Z) |

Same sensor, same readings; the only differences are the 15-minute offset moving an
edge by one hour, +1 kWh one way and −1 kWh the other. After the overlap
`jupiter_load_history.ac_kwh` ends at 2026-08-20T13:00Z: the raw `ac_power_w` stops at
08-19T14:14:34Z (plug physically unplugged) and the last 23 hourly values are carried
forward (§4.5). **From 2026-08-20T14:00Z the A/C series is absent — not zero.**

### 4.4 Q4 — whole-home `grid_power_w`

| Comparison (W) | n | zeus | jupiter | Bias | MAE | r |
|---|---|---|---|---|---|---|
| Hourly mean, all full hours | 216 | 1021.1 | 1021.4 | +0.03 % | 46.4 (4.5 %) | 0.986 |
| …hours where zeus wrote exactly 4 samples | 134 | 948.7 | 947.2 | −0.16 % | **5.3 (0.56 %)** | 0.9993 |
| …hours where zeus wrote extra samples | 82 | 1139.5 | 1142.8 | +0.29 % | 113.5 (10.0 %) | 0.971 |
| LOCF at the hour (what the trainer integrates) | 219 | 1039.2 | 1026.6 | −1.2 % | 62.2 (6.0 %) | 0.922 |

**#202's claim holds.** In the raw trace jupiter's quarter-hour values equal zeus's to
the third decimal (173.364 W at 06:45, 172.549 W at 07:00). The LOCF values the
trainer would use are bit-identical in **182 of 219 hours**; 15 hours differ by more
than 100 W, all in hours where zeus wrote additional intra-quarter samples that
jupiter never had (largest: 07-26T16:00Z, zeus 5287 W vs jupiter 1709 W). In the
union the trainer merges the raw samples before LOCF, so during the overlap it sees
both. No negative values on either side.

### 4.5 Q5 — the seam and the holes

**Seam.** `merge_series` lets jupiter win every timestamp it has, so the
critical-load union is zeus up to **2026-07-20T20:00Z** and jupiter from
**2026-07-20T21:00Z** — nine days *before* the flip. The flip therefore replaced 217
already-trained-on zeus hours with jupiter values in one step (replayed in §4.6). Same
seam for `ac_kwh`. For whole-home the merge is on raw samples: zeus only until
07-20T20:26:33Z, both until zeus's last sample at 07-29T22:22:33Z, jupiter only after.

**Gaps > 1 h, 2026-06-23 → 2026-10-05T19:00Z**

| Series | Last point before | First point after | Missing |
|---|---|---|---|
| Union `kwh` | 2026-08-20T13:00 | 2026-08-27T22:00 | **176 h** |
| Union `kwh` | 2026-09-29T16:00 | 2026-09-30T10:00 | **17 h** |
| `jupiter_state.grid_power_w` | 2026-08-19T14:14:34 | 2026-08-26T20:23:52 | **7 d 6 h 9 min** (the reported hole — confirmed) |
| `jupiter_state.grid_power_w` | 08-29T11:11 | 08-29T16:15:55 | 304 min |
| `jupiter_state.grid_power_w` | 09-08T12:19 | 09-08T16:15:57 | 236 min |
| `jupiter_state.grid_power_w` | 09-10T14:38 | 09-10T17:01:03 | 143 min |
| `jupiter_state.house_load_w` | 2026-08-19T14:14:34 | 2026-08-27T21:26:24 | 8 d 7 h 12 min |
| `jupiter_state.house_load_w` | 2026-09-28T17:15:09 | 2026-09-30T09:45:42 | 40 h 30 min |
| `jupiter_state.house_load_w` | same three short gaps as grid, plus 09-18 (136 min) and 10-05T16:45 → 18:45:53 (120 min) | | |
| `zeus_state.grid_power_w` | 06-29T19:02 | 06-29T21:52:06 | 170 min |

The zeus era and the seam have no gap. Does `jupiter_load_history.kwh` have "the same
hole" as `grid_power_w`? **The same event, different bounds**: the raw house-load
samples stop at the same second (08-19T14:14:34Z) but return a day later
(08-27T21:26:24Z, matching the `office_` entity repoint, gitops #301); and the hourly
series does not stop when the samples do —

**Fabricated hours.** The writer re-integrates a 1-day lookback each refresh and LOCF
carries the last reading across any gap inside it. So after samples stop, it keeps
writing the last value for ~23 more hours, and it fills every shorter gap completely.
Together with sensor flat-lines, the union contains these runs of identical values:

| Run (UTC, hour starts) | Hours | Value kWh | Cause |
|---|---|---|---|
| 07-24T20 → 07-26T16 | 45 | 0.635 | sensor freeze (zeus shows the same 44 h) |
| 08-19T06 → 08-20T13 | 32 | 0.266 | 9 h flat-lined, then 23 h carried after samples stopped |
| 08-29T12 → 16 | 5 | 0.218 | carried across the 304-min gap |
| 08-31T04 → 14 | 11 | 0.212 | staleness deadlock (`docs/incidents/2026-08-31-bluetti-staleness-deadlock.md`) |
| 09-08T13 → 16 · 09-10T14 → 17 | 4 + 4 | 0.350 · 0.210 | carried across short gaps |
| 09-13T00 → 03, then 04 → 21 | 4 + 18 | 0.653, then **0.000** | flat-line, then 18 h of zero load — cause not established here |
| 09-18T15 → 09-20T17 | 51 | **0.607** | the Bluetti reload placeholder (607 W, cards #319/#320) held for two days |
| 09-28T18 → 09-29T16 | 23 | 0.607 | carried after samples stopped at 17:15 |

`jupiter_state.grid_power_w` additionally sat at exactly 1908.774 W for **54.5 h**
(2026-08-01T10:00 → 08-03T16:30Z) while house load kept moving. It has had no
flat-lined hour since 08-26.

**What a training window ending 2026-10-05T19:00Z contains**

| | 30 days (from 09-05T19Z) — today's setting | 90 days (from 07-07T19Z) |
|---|---|---|
| `critical_load` hours present / expected | 703 / 720, all jupiter | 1967 / 2160 (314 zeus + 1653 jupiter) |
| …missing | 17 | 193 |
| …flat-lined, carried or placeholder | **104 (14.8 %)** — incl. 74 h at the 0.607 placeholder and 18 h at 0 (plus 3 isolated hours at exactly 0.607, not counted) | **197 (10.0 %)** |
| `ac_kwh` hours | **0** → two-component rung cannot fit; model is the single temperature rung | 1051, all before 2026-08-20T14Z (last 23 carried) |
| `whole_home` hours with no sample | 5 of 720 (LOCF-filled) | **182 of 2160**, 174 of them one block that the trainer fills with a constant 0.920 kWh |
| `whole_home` flat-lined hours | 0 | 54 (08-01 → 08-03) |

Two traps specific to the 90-day window:

1. **Whole-home:** `power_samples_to_hourly_kwh` has no staleness bound, so the 7-day
   hole becomes 174 consecutive hours of 0.920 kWh — one full week, i.e. one sample in
   every (weekday,hour) bucket out of ~13. It drags night buckets (~0.3 kWh) up by
   about +0.05 kWh and midday buckets (~2.1 kWh) down by about −0.09 kWh.
2. **Critical-load:** with ≥ 24 aligned A/C slots `TwoComponentForecaster` activates
   and fits `base = total − ac` **only on timestamps where both exist** — i.e. only
   07-07 → 08-20. Everything since 08-20 would be ignored for the base, and a summer
   A/C model would be resurrected for a plug that is unplugged.

### 4.6 Q6 — replay of the flip

The first post-flip training run (CronJob `17 */6 * * *`) was 2026-07-30T00:17Z. Its
30-day window was rebuilt both ways from the bucket and fitted with the
`BaselineForecaster` rule (mean per Brussels (weekday, hour), 4–5 samples per bucket):

| | zeus only | union: same 717 h, 217 replaced | union incl. 2 fresh hours |
|---|---|---|---|
| Global mean kWh/h | 0.6742 | 0.6760 (+0.27 %) | 0.6795 (+0.79 %) |
| Σ of 24 hour-of-day means | 16.18 | 16.22 (+0.27 %) | 16.30 (+0.75 %) |
| Hour-of-day means, mean / max move | — | 0.012 / 0.042 kWh | 0.016 / 0.053 kWh |
| (weekday,hour) buckets moved > 0.05 / > 0.10 / > 0.20 kWh | — | 26 / 8 / 2 of 168 | 28 / 9 / 3 |
| Bucket move, mean / p95 / max | — | **0.021** / 0.096 / 0.228 kWh | 0.023 / 0.102 / 0.302 kWh |
| Forecast for Thu 07-30 (kWh/day) | 18.20 | **17.95 (−1.4 %)** | 18.34 (+0.75 %) |
| …evening 17–22 local | 6.86 | 6.74 (−0.12) | 6.74 (−0.12) |
| Forecast for Fri 07-31 (kWh/day) | 15.76 | 15.90 (+0.9 %) | 15.90 (+0.9 %) |

For scale: dropping any one calendar week from the zeus-only window — which the
rolling window does to itself every week — moves the bucket means by **0.066 kWh** on
average, three times the swap. The pooled within-bucket SD is 0.39 kWh, so a 4-sample
bucket mean carries a standard error of ~0.20 kWh before any swap. The A/C corpus was
identical in 215 of 217 hours, so the model rung did not change either.

## 5. Incidents in the data (2026-07-20 → 2026-10-05)

| When (UTC) | What the series show | Reference |
|---|---|---|
| 07-24T20 → 07-26T15 | house load frozen at 635 W on both controllers | #211 (stale-telemetry failsafe, deployed 07-26) |
| 07-29T21:57 | union flags flipped with the zeus decommission | gitops `d5e6c44`, #169 / #264 |
| 08-01T10 → 08-03T16:30 | whole-home grid power frozen at 1908.8 W | not attributed |
| 08-19T14:14:34 → 08-26/27 | all `jupiter_state` realized fields stop; grid returns 08-26T20:23:52, house load 08-27T21:26:24 | end matches the `office_` entity repoint (#254, gitops #301); start not attributed. A/C plug unplugged 08-19 and never returns |
| 08-31T04 → 14 | house load flat at 212 W | `docs/incidents/2026-08-31-bluetti-staleness-deadlock.md` (#259) |
| 09-13T04 → 21 | house load exactly 0 W | not attributed |
| 09-18T15 → 09-20T17 | house load held at the 607 W reload placeholder | #319 / #320 (lar 0.20.0 rejects placeholders — on `develop` as of this report) |
| 09-28T17:15 → 09-30T09:45 | house load samples absent | not attributed |

## 6. Verdicts

**For #228 — could the union flip have fed the trainer materially different data on
2026-07-30? NO.**

- Bias of the jupiter-side series: +0.9 % (+1.1 % live), CI −2.7…+4.9 %. A bias large
  enough to matter (> 5 %) is excluded.
- The flip did change the corpus — 217 hours swapped at once, 75 of 168 buckets moved
  — but by 0.021 kWh on average, and the 07-30 forecast by −1.4 % (−0.26 kWh over the
  day, −0.12 kWh in the evening). That is inside the trainer's ordinary week-to-week
  drift.
- The 07-30 failure was a plan objective oscillating between consecutive 15-minute
  cycles and 41 kWh of churn. A training artifact is rebuilt every 6 hours and is
  constant in between; it cannot be the source of a per-cycle oscillation. (This is
  an inference from the trainer schedule, not a replay of the plans.)
- The 45-hour 0.635 freeze of 07-24/26 sat in the 07-30 window too (6 % of it) — but
  identically on the zeus side, so it is not an effect of the flip.

"Biased jupiter-side integration" is not a credible root cause of that day. PR #272's
"most likely driver" should be read as superseded on this point; its other candidates
(lar 0.18.0 shipping in the same release, the collapsed price spread) are untouched by
this report.

**For the forecaster work — is a 90-day window safe today?**

| Target | 30-day window | 90-day window | Clean from |
|---|---|---|---|
| `critical_load` | usable but 15 % of its hours are not measurements and 17 are missing | **NOT safe**: 193 missing + 197 fabricated hours, the A/C-intersection trap, and a summer/autumn mix | **2026-09-30T10:00Z** (5 days). A 30-day window is clean from 2026-10-30, a 90-day window from 2026-12-29 — if no new freeze occurs |
| `whole_home` | **clean** (5 LOCF-filled hours, no flat-lines) | **NOT safe**: 174 constant hours from the unbounded LOCF and a 54-hour flat-line | **2026-08-26T21:00Z** (40 days). A 90-day window is clean from 2026-11-24 |

## 7. Limits — what this data cannot show

- **Nine days, two of them frozen.** 173 live hours give 7–8 samples per hour-of-day.
  A bias inside ± 5 % and an hour-of-day phase effect of ± 20 % at single hours are
  both below what this window can resolve. No further overlap can ever be collected:
  zeus is gone.
- **Mid-summer, one site.** Nothing here says how the two would compare in a heating
  or shoulder season, or on a site without a 500 W cycling load.
- **Both sides read the same HA sensor.** Agreement between them says nothing about
  the sensor being right; the freeze is the proof.
- **The "4-reading hourly mean" is not ground truth** — it is four point samples, one
  of which is zeus's own (nearly) and one jupiter's next-hour value. It bounds the
  point-sampling noise; it does not measure the hour's energy.
- **The flip replay uses the baseline rung.** The production artifact on 07-30 was the
  two-component/temperature ladder with Open-Meteo temperatures, which were not
  replayed, and the baked artifacts of 07-29/07-30 were not inspected.
- **Not checked:** flat-lines in `zeus_state.grid_power_w` before 07-20; the cause of
  the 08-01, 09-13 and 09-28 events.

## 8. Recommendations

1. **#228: close the "un-soaked union fed bad data" line.** Nothing to roll back; the
   union flags stay on. No correction factor is warranted (bias +1 %, unresolved sign).
2. **Do not raise `history_days` to 90 now** — for either target (§6). If a longer
   window is wanted for `whole_home`, 40 days is the most that is clean today.
3. **Add a guard in the trainer before any window change** (jupiter repo, follow-up
   card):
   - bound LOCF carry in `power_samples_to_hourly_kwh` — emit no hour whose newest
     sample is older than ~30 min — in both the trainer's whole-home path and the
     reporting `jupiter_load_history` writer;
   - drop flat-lined hours (zero spread across the hour's readings, or ≥ 3 identical
     consecutive hourly values), exact zeros and the 607 W placeholder before fitting;
   - make `TwoComponentForecaster` require A/C history that reaches the recent end of
     the load history, else stay on the single rung;
   - export the fraction of training hours masked, and alert on it.
4. **Consider replacing the point sample with a real hourly mean** in the
   `jupiter_load_history` writer (time-weighted mean of the readings in [T, T+1)).
   It removes the 15-minute offset and attacks the target noise directly (a single
   reading is off by 29–34 % RMSE against the 4-reading mean today; how much of that an
   average recovers was not measured). It deliberately breaks "zeus parity" and needs
   the goldens re-pinned; the
   1-minute `jupiter_state` samples since 2026-07-20 allow the jupiter era to be
   recomputed. Forecaster-work decision, not a prerequisite for anything above.
5. **Correct the docs** when that card is worked: the README's "per-control-cycle
   samples … differ by sampling density" and the values comment "verified
   same-cadence" both misdescribe the mechanism (§4.2). `include_untagged: true` is
   now moot for tervuren — both windows start after 2026-07-04.
6. **No follow-up overlap soak** — impossible, and unnecessary. Re-run §4.5 after
   2026-10-30 to confirm the 30-day critical-load window has rolled clean.

**What would change the verdict:** baked artifacts for 07-29 vs 07-30 that differ far
more than the replay (e.g. a rung change), or evidence that the lar's forecast input
changes per cycle rather than per training run.

## Appendix A — reproduction queries

All through Grafana: `POST /api/ds/query` with
`{"from":"now-120d","to":"now","queries":[{"refId":"A","datasource":{"type":"influxdb","uid":"influxdb"},"rawQuery":true,"query":"<flux>"}]}`.
Run 2026-10-05 ~19:00Z.

```flux
// A1 extents and counts per series
from(bucket:"zeus") |> range(start: 2026-06-01T00:00:00Z)
  |> filter(fn:(r)=> r._measurement=="zeus_load_history" or r._measurement=="jupiter_load_history")
  |> group(columns:["_measurement","_field","site_id"])
  |> reduce(identity:{n:0, first: time(v:0), last: time(v:0)},
       fn:(r,accumulator)=>({n: accumulator.n+1,
         first: if accumulator.n==0 then r._time else accumulator.first, last: r._time}))

// A2 the overlap, both fields, side by side (Q1, Q3)
from(bucket:"zeus") |> range(start: 2026-07-20T12:00:00Z, stop: 2026-07-30T12:00:00Z)
  |> filter(fn:(r)=> (r._measurement=="zeus_load_history" or r._measurement=="jupiter_load_history")
       and (r._field=="kwh" or r._field=="ac_kwh"))
  |> map(fn:(r)=>({_time: r._time, _value: r._value,
       k: (if r._measurement=="zeus_load_history" then "z_" else "j_") + r._field}))
  |> group() |> pivot(rowKey:["_time"], columnKey:["k"], valueColumn:"_value") |> sort(columns:["_time"])

// A3 zeus kwh before the overlap, for the flip replay (Q6); tagged wins the 07-04T19 duplicate
from(bucket:"zeus") |> range(start: 2026-06-23T00:00:00Z, stop: 2026-07-20T21:00:00Z)
  |> filter(fn:(r)=> r._measurement=="zeus_load_history" and r._field=="kwh")
  |> map(fn:(r)=>({_time: r._time, _value: r._value, tagged: if exists r.site_id then 1 else 0}))
  |> group() |> sort(columns:["_time","tagged"])

// A4 jupiter_state.house_load_w per hour: mean / count / stddev (Q2); same shape with fn: spread for flat-lines
d = from(bucket:"zeus") |> range(start: 2026-07-20T20:00:00Z, stop: 2026-07-30T00:00:00Z)
  |> filter(fn:(r)=> r._measurement=="jupiter_state" and r._field=="house_load_w")
  |> keep(columns:["_time","_value","_start","_stop"])
d |> aggregateWindow(every: 1h, fn: mean, timeSrc: "_start", createEmpty: false)   // also count, stddev

// A5 how often the banked value actually changes (Q2): minute-of-quarter-hour of every change
from(bucket:"zeus") |> range(start: 2026-07-21T00:00:00Z, stop: 2026-07-24T20:00:00Z)
  |> filter(fn:(r)=> r._measurement=="jupiter_state" and r._field=="house_load_w")
  |> keep(columns:["_time","_value"]) |> group() |> sort(columns:["_time"])
  |> difference() |> filter(fn:(r)=> r._value != 0.0)
  |> map(fn:(r)=>({r with minute: uint(v: r._time) / uint(v: 60000000000) % uint(v: 15), _value: 1}))
  |> group(columns:["minute"]) |> count()

// A6 raw trace around one disagreement (Q2, Q4)
from(bucket:"zeus") |> range(start: 2026-07-23T06:40:00Z, stop: 2026-07-23T07:06:00Z)
  |> filter(fn:(r)=> (r._measurement=="jupiter_state" and (r._field=="house_load_w" or r._field=="grid_power_w"))
       or (r._measurement=="zeus_state" and (r._field=="grid_power_w" or r._field=="realized_load_kwh")))
  |> group() |> sort(columns:["_time"])

// A7 whole-home per hour, each writer: mean, count, and LOCF-at-the-hour (Q4)
g = (m) => from(bucket:"zeus") |> range(start: 2026-07-20T20:00:00Z, stop: 2026-07-30T00:00:00Z)
  |> filter(fn:(r)=> r._measurement==m and r._field=="grid_power_w")
  |> keep(columns:["_time","_value","_start","_stop"]) |> group()
g(m:"zeus_state") |> aggregateWindow(every: 1h, fn: mean, timeSrc: "_start", createEmpty: false) // also count
g(m:"zeus_state") |> aggregateWindow(every: 1h, fn: last, timeSrc: "_stop",  createEmpty: false) // LOCF at T
// …and the same three for m:"jupiter_state"

// A8 gaps > 1 h (Q5) — per series, and for the union of both kwh series
from(bucket:"zeus") |> range(start: 2026-06-23T00:00:00Z)
  |> filter(fn:(r)=> (r._measurement=="zeus_load_history" or r._measurement=="jupiter_load_history") and r._field=="kwh")
  |> keep(columns:["_time","_value"]) |> group() |> sort(columns:["_time"]) |> unique(column:"_time")
  |> elapsed(unit: 1m) |> filter(fn:(r)=> r.elapsed > 60)
// per series: same with one measurement/field (jupiter_state grid_power_w / house_load_w / ac_power_w, zeus_state grid_power_w)

// A9 runs of identical consecutive hourly values (Q5)
from(bucket:"zeus") |> range(start: 2026-06-23T00:00:00Z)
  |> filter(fn:(r)=> r._measurement=="jupiter_load_history" and r._field=="kwh")
  |> keep(columns:["_time","_value"]) |> group() |> sort(columns:["_time"]) |> unique(column:"_time")
  |> duplicate(column:"_value", as:"lvl") |> difference(columns:["_value"])
  |> stateCount(fn:(r)=> r._value == 0.0, column:"run") |> filter(fn:(r)=> r.run >= 3)
  |> map(fn:(r)=>({_time: r._time, run: r.run, lvl: r.lvl,
       start: time(v: int(v: r._time) - (r.run * 3600000000000))}))
  |> group(columns:["start"]) |> max(column:"run")

// A10 window contents (Q5): start = 2026-09-05T19:00:00Z (30 d) or 2026-07-07T19:00:00Z (90 d), stop = 2026-10-05T19:00:00Z
//   critical-load: count unique hours, hours from jupiter, hours == 0.607, hours == 0.0 over both kwh series
//   whole-home:    hours with no sample
from(bucket:"zeus") |> range(start: 2026-07-07T19:00:00Z, stop: 2026-10-05T19:00:00Z)
  |> filter(fn:(r)=> (r._measurement=="zeus_state" or r._measurement=="jupiter_state") and r._field=="grid_power_w")
  |> keep(columns:["_time","_value","_start","_stop"]) |> group()
  |> aggregateWindow(every: 1h, fn: count, createEmpty: true) |> filter(fn:(r)=> r._value == 0) |> count()
```

## Appendix B — code references

| Concern | Where |
|---|---|
| The shared "integrator" (LOCF at the hour start × 1 h) | jupiter `packages/dispatch/jupiter_dispatch/energy.py::power_samples_to_hourly_kwh` / `resample_locf` |
| jupiter hourly writer, 1-day lookback | jupiter `services/reporting/jupiter_reporting/load_history.py::write_load_history` |
| zeus hourly series | zeus `zeus/main.py::_load_energy_series` + `zeus/ha_client.py::history_to_series`; written as `load_hist.iloc[-1]` each cycle |
| Union (jupiter wins) and window | jupiter `services/forecast/jupiter_forecast/train.py` (`history_days: 30`), `history.py::merge_series` |
| Bucket model, two-component intersection | jupiter `services/forecast/jupiter_forecast/models.py` (`BaselineForecaster`, `TwoComponentForecaster.fit`) |
| Flags and trainer schedule | gitops `landingzones/jupiter-central/values.yaml` (`critical_load_union_jupiter: true`, `whole_home_union_jupiter: true`, schedule `17 */6 * * *`) |

## Appendix C — arithmetic

- Agreement statistics: over hours where both `j_kwh` and `z_kwh` exist (A2). "Frozen"
  = both exactly 0.635. `bias = mean(j − z)`; percentages divide by `mean(z)`.
- Bias CI: moving-block bootstrap of the hourly differences, block 24 h, 20 000 draws,
  statistic `mean(d)/mean(z)`, 2.5th–97.5th percentile.
- Hour-of-day flag (T3): all but at most one of the available days share the sign of
  `j − z` (|diff| > 0.005 kWh) and |mean diff| > 10 % of the zeus mean for that hour.
- "4-reading hourly mean": `mean(jupiter_state.house_load_w)` over [T, T+1) / 1000 (A4).
- Flip replay: zeus series = A3 + the zeus column of A2, restricted to
  ≥ 2026-06-30T00:17Z; union = that with jupiter values overriding 07-20T21 → 07-29T21Z
  (and, in the third column, adding 07-29T22 and 23Z). Buckets are the mean per
  Europe/Brussels (weekday, hour); the forecast for a day is the sum of its 24 bucket
  means.
