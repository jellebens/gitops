# jupiter-shadow — shadow parity harness (P3.6, card #141; fine-grained inputs #147)

Monitoring-only landing zone. Originally it proved, **per cycle**, that the
tervuren lar's **shadow** plan matched zeus's **actual** dispatch — the signal
that gated the P4 cutover. **Since the 2026-07-06 go-live (ADR-0023) the roles
are swapped:** the lar is the LIVE commander and zeus runs demoted as the
cross-check, so the same joins now cross-check zeus's advisory plan against the
live lar dispatch. Series names and semantics are unchanged (a divergence is a
divergence either way); `guard_conflict` is the one rule whose direction
flipped (card #147, below).

## Approach: Prometheus recording rules + a Grafana dashboard (NO new service)

Both stacks already export everything the join needs as scraped metrics, so
this is **rules + dashboard only** — no new service, no lar edit (the lar is
owned by #142), no MQTT consumer:

- **zeus actual** (ns `zeus`, **no `site_id` label** — the single tervuren
  battery): `zeus_target_charge_kw`, `zeus_target_discharge_kw`,
  `zeus_price_source` (0=primary 1=fallback 2=cache 3=none 4=partial),
  `zeus_forecast_source`, `zeus_charge_guard_trips_total`.
- **lar shadow** (ns `jupiter-tervuren`, all `site_id="tervuren"`):
  `jupiter_lar_target_charge_kw`, `jupiter_lar_target_discharge_kw`,
  `jupiter_lar_price_source` (0=primary 1=cache 2=none),
  `jupiter_lar_forecast_source`.

The `zeus_*` series carry no `site_id`, so every zeus term is
`label_replace`'d with `site_id="{{ site.id }}"` (default `tervuren`) and joined
`on(site_id)` against the lar term. If either side stops being scraped, the
join yields no samples and the `jupiter_shadow_*` series go **absent** (the
dashboard shows "no data", never a false 0) — that absence is the
`jupiter_shadow_both_present` gate.

Intent is derived exactly as the lar's own `jupiter_lar.plan._intent`:
`charge_kw>0 → 1 (charging)`, `discharge_kw>0 → 2 (discharging)`, else
`0 (idle)`, encoded `(charge>0) + 2*(discharge>0)`.

## Metrics (`templates/prometheusrule.yaml`) — all `site_id`-labelled

| series | meaning |
| --- | --- |
| `jupiter_shadow_zeus_intent_code` / `_cell_intent_code` | derived intent 0/1/2 per side |
| `jupiter_shadow_zeus_setpoint_kw` / `_cell_setpoint_kw` | signed net setpoint (`discharge − charge`; + = discharge) |
| `jupiter_shadow_both_present` | 1 iff both stacks exporting (absent otherwise) |
| `jupiter_shadow_intent_match` / `_divergence` | 1/0 the intents agree / differ |
| `jupiter_shadow_setpoint_delta_kw` / `_setpoint_abs_delta_kw` | `zeus_net − cell_net` and its magnitude |
| `jupiter_shadow_price_source_class_match` / `_forecast_source_class_match` | degrade-class parity (primary vs degraded) per feed |
| `jupiter_shadow_inputs_source_match` | 1 iff both feeds' source-class agree |
| `jupiter_shadow_logic_divergence` | intents differ **and** inputs source-class agree — the classic gate (unchanged) |
| `jupiter_shadow_inputs_divergence` | intents differ **but** source-class differs — expected/benign |
| `jupiter_shadow_zeus_soc_pct` / `_cell_soc_pct` | SoC input per side (#147; cell side = `jupiter_lar_soc_pct`) |
| `jupiter_shadow_soc_delta_pct` / `_soc_match` | \|zeus − lar\| SoC and within-band match (`socDeltaPct`, default 2 pp) |
| `jupiter_shadow_zeus_peak_kw` / `_cell_peak_kw` | running month peak per side (#147; cell side = `jupiter_reporting_capacity_peak_kw`) |
| `jupiter_shadow_peak_delta_kw` / `_peak_match` | \|zeus − lar\| peak and within-band match (`peakDeltaKw`, default 0.1 kW) |
| `jupiter_shadow_inputs_equal` | **fine-grained** inputs equality (#147): source-class ∧ SoC ∧ peak |
| `jupiter_shadow_logic_divergence_strict` | intents differ **and** fine-grained inputs agree — the tightened gate (#147) |
| `jupiter_shadow_inputs_divergence_price` / `_forecast` / `_soc` / `_peak` | the inputs divergence split by WHICH input differed (#147; not mutually exclusive) |
| `jupiter_shadow_guard_conflict` | **redefined #147 (roles swapped):** the LIVE lar tripped its charge-guard (`jupiter_charge_guard_trips_total`, <15m — a real veto) while zeus's cross-check plan wanted to charge |

## Parity coverage vs gaps

**Full from metrics:** intent-match, setpoint delta (kW), source-**class**
inputs parity, guard-conflict.

**Source-class comparison.** The two source enums are **not** numerically
identical (zeus 0..4, lar 0..2), so only the derived degrade **class** (`==0`
primary/healthy vs `!=0` degraded) is compared, never the raw code.

**Fine-grained inputs equality (closed by card #147).** The lar now exports
`jupiter_lar_soc_pct` directly, and the **reporting-service** (which already
subscribes `jupiter/+/plan` with its existing `reporting` EMQX user — no new
consumer or broker user was needed) re-exposes the plan doc's `inputs`
fingerprint as `jupiter_reporting_plan_*` gauges plus
`jupiter_reporting_capacity_peak_kw`. That upgraded the harness from
source-class-only to `jupiter_shadow_inputs_equal` (source-class ∧ SoC ∧
running peak) and the tightened `jupiter_shadow_logic_divergence_strict` gate,
with the per-input `jupiter_shadow_inputs_divergence_{price,forecast,soc,peak}`
split for attribution.

**Still not cross-comparable:** `price_curve_etag` and `forecast_trained_at`
have **no zeus-side counterpart series**, so cross-stack equality on them is
impossible from Prometheus. They ARE exposed lar-side
(`jupiter_reporting_plan_price_curve_etag_info`,
`jupiter_reporting_plan_forecast_trained_at_timestamp_seconds`) for
change-attribution — "did the curve/model change between these two cycles".

**Deployment-order caveat (#147).** The new series only produce samples once
the jupiter release shipping the #147 lar + reporting changes is deployed:
until then `jupiter_shadow_{soc,peak}_*`, `inputs_equal`,
`logic_divergence_strict`, the `_soc`/`_peak` splits AND the redefined
`guard_conflict` evaluate to **absent** (never a false 0), while every
pre-#147 series keeps working unchanged. `cell_peak_kw` additionally needs the
lar to have a live month-peak HA read (`running_peak_kw` is `null` before one
lands). The lar pre-seeds `jupiter_charge_guard_trips_total` at 0 from #147 on,
so post-release `guard_conflict` is a live 0/1 rather than
absent-until-first-trip.

## Dashboard

`dashboards/jupiter-shadow-parity.json`, uid **`jupiter-shadow-parity`**,
provisioned via the ConfigMap the kube-prometheus-stack Grafana sidecar
discovers (`grafana_dashboard: "1"`) — same pattern as `landingzones/zeus`. A
**new** dashboard; the kiosk and every existing dashboard are untouched.
Panels: parity-at-a-glance stats, zeus vs lar intent state-timelines, a
match/inputs/logic attribution timeline, net-setpoint + delta timeseries,
source-class match timelines, and a soak-summary row (intent-match fraction,
logic-divergence minutes, max |delta| over the selected window).

## Alerts (warning only — the harness never actuates; these are P4-readiness)

`JupiterShadowHarnessNoData`, `JupiterShadowLogicDivergence` (the gate; its
description points at the #147 strict/per-input series for attribution),
`JupiterShadowSetpointDelta` (`values.yaml prometheusRule.setpointDeltaKw`,
default 0.5 kW), `JupiterShadowGuardConflict` (#147: now fires on a REAL live-lar
guard veto conflicting with the zeus cross-check plan).

Plus, in its own file/flag, `JupiterShadowLogicGateBlind` — see below.

## ⚠ A blind gate is not a passing gate (card #196)

`jupiter_shadow_logic_divergence` is a **product**:

```
logic_divergence = divergence * inputs_source_match
```

When `inputs_source_match` is `0`, that product is identically `0` **no matter
how far the two controllers' intents actually diverge**. The gate then does not
report "no logic divergence" — it reports **nothing**. Read off a dashboard the
two states are indistinguishable: both are a flat green `0`.

**This is the live state, and has been since the series was born.** Measured
2026-07-16 against the in-cluster Prometheus:

| query | result |
| --- | --- |
| `max_over_time(jupiter_shadow_inputs_source_match[15d])` | `0` — never once 1; first sample 2026-07-05T21:31Z |
| `max_over_time(jupiter_shadow_logic_divergence[92h])` | `0` — structurally, not empirically |
| `avg_over_time(jupiter_shadow_divergence[92h])` | `0.149` — the controllers really do disagree ~1 sample in 6 |
| `avg_over_time(jupiter_shadow_inputs_divergence[92h])` | `0.149` — i.e. **100%** of it filed as "inputs" |
| `zeus_price_source` / `zeus_forecast_source` | `4` (partial) / `1` (fallback) |
| `jupiter_lar_price_source` / `jupiter_lar_forecast_source` | `0` / `0` (primary) |

Because the two stacks sit on different feed **classes** (one primary, one
degraded), both source-class match terms are `0`, so the multiplier is `0`, so
the gate is pinned. **`jupiter_shadow_logic_divergence` has never carried
information.** Same class of defect as the 68h reporting wedge (#181): a
green-looking number that validates nothing.

Note also that the whole ~15% raw divergence lands in
`jupiter_shadow_inputs_divergence`, which this README labels *expected/benign*
above — a label that assumes the mismatch is **transient**. Here it is
**permanent**, so that label is doing work it was never designed for.

**The guard:** `JupiterShadowLogicGateBlind`
(`templates/gate-blind-prometheusrule.yaml`, `values.yaml
prometheusRule.gateBlind`, default `for: 30m`) fires whenever
`inputs_source_match == 0` for a site that is being compared, so a blind gate is
**loud instead of green**. It is a separate PrometheusRule with its own
`enabled` flag because it guards the *validity* of the harness rather than being
part of it, and it retires on a different schedule (moot once zeus is
decommissioned, #169). A both-sides-down gap makes the join **absent**, which
does not match `== 0` — that case stays covered by `JupiterShadowHarnessNoData`.

**Do not sign off a soak or a P4 cutover on `logic_divergence = 0` while this
alert is firing.** To clear it, the two stacks must be put back on the same feed
class (the root cause — zeus's price/forecast feeds — is card #196 part b, held
off under the jupiter-tervuren deploy freeze). To see the real disagreement
meanwhile, read `jupiter_shadow_divergence` and the
`jupiter_shadow_inputs_divergence_{price,forecast,soc,peak}` split.

### Why `JupiterShadowSetpointDelta` was left at 0.5 kW (card #196)

The #164 pre-check flagged this rule as noise: `setpoint_abs_delta_kw` runs p95
~1.29 kW against a 0.5 kW threshold and is over it ~30% of the time, yet the
alert last fired 07-12T11:05Z and otherwise only flaps in pending. The
threshold was nevertheless **kept as-is** — the data supports neither retuning
nor retiring:

- **It is not structurally dead** (unlike the gate above). The rule needs a
  **2h continuous** breach, and over 15d the worst 2h-window minimum reached
  **2.458 kW** — it *did* clear the bar, and it *did* fire. It is a working rule
  that correctly stays quiet when the disagreement is transient.
- **The p95-vs-threshold comparison mixes two different quantities.** p95 is an
  *instantaneous* quantile; the rule keys on *sustained* breach. Over the last
  92h the worst 2h-window minimum was **0.335 kW** — under 0.5 — which is why it
  is silent. The delta is spiky, not high: it sits at ~0 for **30%** of samples
  (both sides idle). That is the signal doing its job, not a mis-set threshold.
- **This window is contaminated by the blindness above.** zeus has been on
  partial price / fallback forecast for the entire life of the series while the
  lar ran primary — *different inputs produce different setpoints*. Retuning
  "to observed reality" would bake a degraded-feed artefact into the threshold
  permanently, and the distribution will move once the feeds are fixed. Setting
  a threshold from data this very card exists to distrust would be the same
  mistake one level down.

Re-evaluate after #196 part b lands and a clean same-feed window exists. If the
flapping-in-pending is itself judged noisy, the honest fix is a duty-cycle expr
(breach *fraction* over a window) rather than a higher bar — a separate change,
not a silent threshold bump.

## Tolerances (`values.yaml prometheusRule.*`, card #147)

| knob | default | rationale |
| --- | --- | --- |
| `socDeltaPct` | `2.0` | both stacks read the same HA SoC entity at different instants; ~one cycle of drift on the 13 kWh pack |
| `peakDeltaKw` | `0.1` | both read the meter's own monthly billing register; absorbs read-timing skew across a quarter boundary |
