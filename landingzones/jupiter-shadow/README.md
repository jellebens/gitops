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

## Tolerances (`values.yaml prometheusRule.*`, card #147)

| knob | default | rationale |
| --- | --- | --- |
| `socDeltaPct` | `2.0` | both stacks read the same HA SoC entity at different instants; ~one cycle of drift on the 13 kWh pack |
| `peakDeltaKw` | `0.1` | both read the meter's own monthly billing register; absorbs read-timing skew across a quarter boundary |
