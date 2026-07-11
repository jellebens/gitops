# Savings-parity soak report — card #164 (jupiter vs zeus, tervuren)

- **Date:** 2026-07-11 (data as of 2026-07-11T10:20Z)
- **Author:** Clio (soak & observation-report agent)
- **Card:** [#164 JUPITER: savings parity cross-check SOAK + owner sign-off](https://trello.com/c/ukTOKVw8)
- **Gates:** kiosk dashboard migration (#165) → HA sensor swap (#166) → zeus decommission (#169)
- **Sources:** Prometheus (kube-prometheus-stack, ns `observability`, retention 15d — covers the whole window), gitops git history, PrometheusRule `reporting-savings-parity` ([landingzones/jupiter-central/templates/reporting-parity-prometheusrule.yaml](../../landingzones/jupiter-central/templates/reporting-parity-prometheusrule.yaml)). All queries quoted in Appendix A.

## 1. Verdict

**INSUFFICIENT DATA — keep soaking. Clean full independent days so far: 0 (zero).**
Owner sign-off is not defensible today. Contrary to the working assumption that
2026-07-08 and 2026-07-09 were clean independent days, the metrics show the
reporting-service fell back to `insufficient_history` at its **first midnight
rollover** (2026-07-07T22:00Z) and its savings gauge sat **frozen at €0.2375
for ~68 hours** (all of 07-08, 07-09 and most of 07-10). Every parity number in
that stretch measures zeus moving against a wedged constant — it validates
nothing about jupiter's savings logic. The genuinely independent, unwedged soak
only began **2026-07-10 ~20:25Z** (after the CNP fix), and its first full day —
today, 2026-07-11 — is in progress and looking excellent (parity ≤ €0.06 all
day so far, €0.038 at 10:20Z).

**Earliest defensible sign-off: 2026-07-16** (after 5 clean full days,
07-11 → 07-15, all green). **Recommended: 2026-07-18** (7 clean days), because
the only genuinely independent evening observed so far (07-07, on the old 0.8.0
model) showed a real €0.60 evening divergence, and the current model has not
yet been through a single evening discharge window.

## 2. The window and its contamination map

Soak window analysed: **2026-07-06T22:00Z → 2026-07-11T10:20Z** (Brussels days
2026-07-07 → 2026-07-11 partial; all "days" below are Europe/Brussels local,
CEST = UTC+2). Prometheus retention is 15d; all series fall well inside it. The
parity recording rules were created 2026-07-06 ~21:52Z (join fixed #161-H-fix,
commit `19d41e4`), so no parity data exists before this window — that is a
series birth, not a retention gap.

| # | Interval (UTC) | Event | Effect on soak data |
|---|---|---|---|
| C1 | until 2026-07-07 ~14:10Z | reporting mirrored zeus (pre-0.8.0) | parity trivially ~0 — meaningless by construction |
| C2 | 2026-07-07 14:10Z → 22:00Z | **0.8.0 independence live** (gitops PR [#143](https://github.com/jellebens/gitops/pull/143), commit `ca83725`; cards [#163](https://trello.com/c/7sHfDq8r)/[#170](https://trello.com/c/jVzETBGV)/[#171](https://trello.com/c/rstOIdgq)) | the ONLY genuine independent stretch before 07-10 evening; real evening divergence observed (see §3) |
| C3 | 2026-07-07 22:00Z → 2026-07-10 ~17:48Z | **WEDGE:** at midnight rollover `jupiter_reporting_savings_source` flipped to `insufficient_history` and never recovered; `jupiter_savings_today_eur` frozen at 0.2375 (baseline 0.2016 / actual 0.2253 frozen too) | 07-08 and 07-09 are NOT clean days; all parity movement is zeus-only |
| C4 | 2026-07-10 17:39Z → 20:25Z | **CNP outage:** 0.11.0 roll (release PR [#161](https://github.com/jellebens/gitops/pull/161), merged 17:46Z) brought a fresh price-service that strictly enforced its ingress allow-list; same-namespace reporting was not on it → import-price fetches blocked, savings blind. Parity series gap 17:45Z→20:30Z; `JupiterReportingSavingsParityNoData` fired 18:20Z→20:29Z. Fixed by gitops PR [#169](https://github.com/jellebens/gitops/pull/169) (commit `e2705ca`), on master via PR [#170](https://github.com/jellebens/gitops/pull/170) 20:23Z | 07-10 blind 2h45m; the fresh 0.11.0 reporting pod restarted with only post-20:25Z accumulation → 07-10 EOD gap €0.81 is an artifact (the "€0.73 today" seen during the incident, grown by end of day) |
| C5 | 2026-07-10 22:00Z | midnight rollover into 07-11 | **survived** — source stayed `independent`, gauge reset correctly (first observed successful rollover) |
| C6 | 2026-07-11 ~10:02Z | 0.12.0 roll (release PR [#181](https://github.com/jellebens/gitops/pull/181), card #179 tracing) | reporting pod replaced; **no visible accumulator reset** — the today figure recomputes from jupiter's own persisted history and continued smoothly (0.119 → 0.206 across the roll) |
| — | every 00:00 local | midnight straddle | the two sides reset asynchronously → parity briefly spikes (up to ~€0.85 for a few minutes). Harmless for the 2h-`for` alert; excluded from EOD readings (taken at 23:55 local) |

## 3. The numbers

### 3.1 Per-day parity (`jupiter_savings_parity_abs_eur`, Brussels days, EOD = 23:55 local)

| Day | Mode (source flag) | max abs | p95 abs | EOD abs | EOD signed | jupiter EOD | zeus EOD | % samples > €0.25 | Clean? |
|---|---|---|---|---|---|---|---|---|---|
| 07-07 | mirror → **independent** 16:10 local | 0.679 † | 0.422 | 0.599 | −0.599 | 0.238 | 0.837 | 10.1% | **NO** (mixed day; real evening divergence) |
| 07-08 | `insufficient_history` (wedged) | 0.600 | 0.224 | 0.169 | −0.169 | 0.2375 (frozen) | 0.407 | 1.4% | **NO** (gauge frozen — green-looking numbers are meaningless) |
| 07-09 | wedged | 0.651 | 0.645 | 0.649 | −0.649 | 0.2375 (frozen) | 0.886 | 31.9% | **NO** |
| 07-10 | wedged → outage → fresh pod | 0.824 | 0.750 | 0.815 | −0.815 | 0.039 (post-outage only) | 0.854 | 8.6% | **NO** |
| 07-11 (partial, → 10:20Z) | **independent** | 0.855 † | 0.057 | 0.038 (at 10:20Z) | +0.038 | 0.205 | 0.168 | 2.7% † | **on track** — first candidate clean day |

† midnight-straddle boundary artifact (see C-map); the 07-11 window excluding
the first ~15 minutes has max ≈ p95 ≈ €0.06.

All values EUR. Units: `*_eur` series are absolute euros of savings-today.
Sample counts per day ~2,850–2,870 (30s recording interval); 07-10 has 2,550
(the 2h45m NoData gap).

### 3.2 Daily banked savings, jupiter vs zeus

zeus banks per-day into `zeus_daily_savings_eur{date=...}`; jupiter's banked
`jupiter_daily_savings` lives in InfluxDB only (not exported to Prometheus) and
was **not sampled** for this report (read access to the InfluxDB pod was not
permitted in this session — flagged, not silently skipped). Proxy used:
end-of-day `jupiter_savings_today_eur` at 23:55 local.

| Day | zeus banked (EUR) | jupiter EOD (EUR) | Comment |
|---|---|---|---|
| 07-07 | 0.8373 | 0.238 | only real independent comparison pre-wedge; jupiter missed the evening bank |
| 07-08 | 0.4065 | 0.2375 | jupiter frozen — not a real figure |
| 07-09 | 0.8863 | 0.2375 | jupiter frozen — not a real figure |
| 07-10 | 0.8536 | 0.0388 | jupiter blind 17:39–20:25Z + fresh pod — artifact |
| 07-11 (→10:20Z) | n/a (in progress) | 0.205 vs zeus 0.168 | tracking within €0.04 |

### 3.3 Structural gap: size and stability

**Cannot yet be assessed.** The expected small structural gap (jupiter
net-flow-from-15-min-SoC vs zeus gross-AC-reads, both VAT-aligned since
#118/#171) is only observable when both sides compute live. That is true for
<1 day of data:

- **07-11 so far:** signed gap averages **+€0.008** (day mean), currently
  +€0.038 — jupiter reads slightly HIGH midday. Well inside the €0.25
  tolerance.
- **07-07 evening (0.8.0 model, superseded):** jupiter flat-lined 16:00→24:00
  local (0.442→0.238) while zeus banked its evening discharge (0.488→0.837) —
  a real −€0.60 divergence in the old model's evening accounting. Card #171
  (savings-model finalization) landed after this; whether the current model
  clears the evening test is **the** open question — no evening of
  current-model data exists yet.

### 3.4 Alert history (`ALERTS{alertname=~"JupiterReportingSavingsParity.*"}`, threshold €0.25 for 2h)

| Alert | Firing (UTC) | Duration | Assessment |
|---|---|---|---|
| Diverged | 2026-07-07 21:31 → 22:15 | 45 min | TRUE positive — real 0.8.0 evening divergence (condition from ~19:31Z, cleared by midnight reset) |
| Diverged | 2026-07-09 02:01 → 04:45 | 165 min | TRUE positive — frozen 0.2375 vs zeus overnight ~−0.03 |
| Diverged | 2026-07-09 21:01 → 22:15 | 75 min | TRUE positive — frozen 0.2375 vs zeus evening surge |
| NoData | 2026-07-10 18:20 → 20:29 | 130 min | TRUE positive — CNP outage (C4) |

**Green since 2026-07-10 22:15Z** (last pending sample; no firing since 20:29Z).
The card's sign-off criterion — "Diverged stays green across the spread" — has
therefore been met for ~12 hours, not days.

### 3.5 Monitoring defects found while reading the data

1. **The wedge was invisible to alerting.** `jupiter_reporting_savings_source`
   said `insufficient_history` for 68h and nothing fired on it; the Diverged
   alert caught it only indirectly (and on 07-08, a mild zeus day, the frozen
   gauge even LOOKED green — p95 €0.22). Recommend a dedicated rule, e.g.
   `max by (site_id) (jupiter_reporting_savings_source{source="independent"}) != 1 for: 30m`.
2. **Dead recording rules.** `jupiter_savings_parity_baseline_abs_eur` and
   `jupiter_savings_parity_actual_abs_eur` have never produced a single sample:
   they join against `zeus_savings_baseline_eur` / `zeus_savings_actual_eur`,
   which zeus does not export (zeus exports only `zeus_savings_today_eur`,
   `zeus_daily_savings_eur`, `zeus_horizon_cum_savings_eur`,
   `zeus_predicted_savings_eur`). Component attribution of any future gap is
   currently impossible — either export the zeus components or drop the rules.
3. jupiter's `jupiter_savings_baseline_eur`/`jupiter_savings_actual_eur` froze
   with the wedge (0.2016/0.2253 for 3 days) — same root cause, worth a check
   that 0.11.0+ refreshes them on the independent path.

## 4. Incidents in the window

- **Reporting `insufficient_history` wedge (NEW finding, unfiled as of this
  report):** reporting-service 0.8.0 flipped to fallback at its first midnight
  rollover (2026-07-07T22:00Z) and never returned to `independent` until the
  pod was replaced at the 0.11.0 roll (2026-07-10 ~17:48Z). Root cause is not
  establishable from metrics alone (rollover logic vs history-window
  requirement vs a stalled refresh loop) — **needs a jupiter-repo
  investigation**. The 07-10→07-11 rollover succeeded on 0.11.0; that is one
  data point, not a fix confirmation.
- **CNP price-service outage** 2026-07-10 17:39–20:25Z: see C4. Cards
  [#164](https://trello.com/c/ukTOKVw8) (soak),
  [#170](https://trello.com/c/jVzETBGV) / [#171](https://trello.com/c/rstOIdgq)
  (independence + savings model); fix PRs gitops
  [#169](https://github.com/jellebens/gitops/pull/169) →
  [#170](https://github.com/jellebens/gitops/pull/170).
- **Rolls:** 0.11.0 (07-10 ~17:48Z) and 0.12.0 (07-11 ~10:02Z). The 0.12.0
  roll demonstrated the accumulator survives a pod restart by recomputing from
  jupiter's own history; the 0.11.0 restart lost the day only because the CNP
  block starved it of import prices at the same time.

## 5. Recommendation

1. **Keep soaking; do not sign off; do not start the kiosk migration (#165).**
   Restart the clean-day counter at 2026-07-11 00:00 local.
2. **Sign-off bar:** ≥5 consecutive clean full days (no source-flag fallback,
   no NoData, Diverged green, midnight rollovers verified), including at least
   2 high-savings evenings (zeus banking >€0.5) with parity inside tolerance.
   Earliest possible review: **2026-07-16**; recommended **2026-07-18** (7
   days, spans weekend + weekday load patterns).
3. **Tonight is the first real test:** watch 07-11 18:00–24:00 local — the
   evening discharge window is where the only genuine divergence ever observed
   (€0.60, 07-07, old model) occurred.
4. **File the wedge** as its own card (jupiter repo): why 0.8.0 fell back at
   midnight and stayed there; whether 0.11.0 fixed it or merely restarted past
   it.
5. **Add the source-flag alert** and **fix or drop the dead component-parity
   rules** (§3.5) so the remaining soak is self-monitoring.
6. What would change the verdict: another `insufficient_history` fallback or a
   Diverged firing during the clean window → hard fail, back to
   engineering; five+ green days incl. evenings → PASS, owner signs, #165
   proceeds.

## Appendix A — reproduction queries

All against Prometheus (`kubectl -n observability port-forward
svc/kube-prometheus-stack-prometheus 9090`), evaluated 2026-07-11 ~10:20–10:35Z.
Brussels-day stats use instant queries at `eval_ts` = day-end 21:55Z (=23:55
local) with a lookback to day-start 22:00Z (=00:00 local):

```
# per-day stats (per day: eval_ts = <day>T21:55:00Z epoch; [86100s] = full day; 07-11 partial used [44108s] @ 10:15Z)
max_over_time(jupiter_savings_parity_abs_eur[86100s])
quantile_over_time(0.95, jupiter_savings_parity_abs_eur[86100s])
avg_over_time(jupiter_savings_parity_signed_eur[86100s])
count_over_time(jupiter_savings_parity_abs_eur[86100s])
jupiter_savings_parity_abs_eur
jupiter_savings_parity_signed_eur
jupiter_savings_today_eur
zeus_savings_today_eur
zeus_daily_savings_eur                      # banked per day, date label
jupiter_savings_baseline_eur / jupiter_savings_actual_eur

# full-window ranges (start=2026-07-06T22:00:00Z, end=now)
jupiter_savings_parity_abs_eur              # step 300s — gap map: single gap 17:45Z→20:30Z 07-10
jupiter_savings_parity_both_present         # step 300s — same gap
jupiter_savings_parity_signed_eur           # step 300s — hourly means
max by (site_id) (jupiter_savings_today_eur)   # step 900s — revealed the 0.2375 freeze
max(zeus_savings_today_eur)                    # step 900s
ALERTS{alertname=~"JupiterReportingSavingsParity.*"}   # step 60s — episodes split on >180s gaps
max by (source) (jupiter_reporting_savings_source)     # step 600s — the source-flag chronicle

# discovery / negatives
/api/v1/label/__name__/values?match[]={__name__=~"jupiter_.*savings.*"}
/api/v1/label/__name__/values?match[]={__name__=~"zeus_.*savings.*"}   # no baseline/actual → dead component rules
{__name__=~"jupiter_daily_savings.*"}       # empty — Influx-only measurement
jupiter_savings_parity_baseline_abs_eur / jupiter_savings_parity_actual_abs_eur   # empty at every eval
/api/v1/status/flags                        # retention 15d

# spike responder (#177/#178)
{__name__=~"jupiter_lar_spike.*"}                                   # instant @now
{__name__=~"jupiter_lar_spike.*_total"}                             # range 2026-07-06T22:00Z→now step 600
sum by (__name__) (increase({__name__=~"jupiter_lar_spike.*_total"}[57488s]))   # since 18:22Z 07-10 → empty
```

## Appendix B — #177 spike-responder OBSERVE phase status

Config (jupiter-tervuren, observe mode — commands nothing): trigger 2.5 kW ×2
consecutive samples, release 1.0 kW ×3, cooldown 120s, HEM poked every 15s.

- **Corrected signal** ([#178](https://trello.com/c/Rcc5CpaJ): battery grid
  input subtracted from HEM import) live since **2026-07-10 ~18:22Z** (site-doc
  commit `ded2c60`, on master 18:19Z via merge commit `2635b2b`).
  **Everything before that is charge-contaminated** — discard.
- **Contaminated era (for the record, not for review):** lar 0.10.1 pod
  (`jupiter-cell-7c8469b6f`) counted `jupiter_lar_spike_would_trigger_total` =
  6 (first event 07-10 12:30Z) and cooldown-suppressed totals of 10 and 5 (two
  label series) by 17:40Z — these are battery-charge self-triggers.
- **Since the corrected signal (18:22Z → 10:20Z, ~16 h, mostly overnight):
  ZERO would-trigger and zero cooldown-suppressed events.** No `*_total`
  counter samples exist from the post-correction pods (labelled counters
  materialize on first event), while the same pods DO export
  `jupiter_lar_spike_state` = 0 and `jupiter_lar_spike_cooldown_remaining_seconds`
  = 0 — the responder is alive and idle. Near-zero overnight is exactly the
  expectation; no daytime spike has occurred yet today.
- **2026-07-17 09:00 activation review:** by then the corrected signal will
  span ~6.6 days — marginally under "a week". Adequate if the coming weekdays
  produce normal daytime consumption spikes; if the observed would-trigger
  count is still ~0 by 07-15, consider whether the 2.5 kW threshold is ever
  reached at this site before activating.
