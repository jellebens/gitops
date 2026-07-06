# jupiter-shadow — shadow parity harness (P3.6, card #141)

Monitoring-only landing zone. It proves, **per cycle**, that the tervuren
lar's **shadow** plan matches zeus's **actual** dispatch — the signal that
gates the P4 cutover (sustained clean parity = safe to flip a site to live).

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
| `jupiter_shadow_logic_divergence` | intents differ **and** inputs source-class agree — **the cutover gate** |
| `jupiter_shadow_inputs_divergence` | intents differ **but** source-class differs — expected/benign |
| `jupiter_shadow_guard_conflict` | zeus tripped its charge-guard (<15m) while the lar planned to charge |

## Parity coverage vs gaps

**Full from metrics:** intent-match, setpoint delta (kW), source-**class**
inputs parity, guard-conflict.

**Partial — `inputs_equal` attribution.** The two source enums are **not**
numerically identical (zeus 0..4, lar 0..2), so only the derived degrade
**class** (`==0` primary/healthy vs `!=0` degraded) is compared, never the raw
code. The fine-grained fingerprint — `price_curve_etag`, `forecast_trained_at`,
`running_peak_kw`, `peak_threshold_kw`, and SoC equality — lives **only** in the
retained MQTT plan doc `jupiter/<site>/plan` (`jupiter_lar.publish
.build_plan_document`, `inputs` block) and is **not scraped**. So a
`jupiter_shadow_logic_divergence` here means *logic OR a same-class-but-
different-curve/SoC input*. Tightening it to full inputs-equality needs a small
MQTT consumer that subscribes `jupiter/<site>/plan` and compares the fingerprint
— a **follow-up**, not a lar edit.

**One-sided signals (metric GAP on the lar, do NOT fix here — lar is #142):**
- The lar exposes **no guard-trip metric** (jupiter #137 lands it). Guard
  conflict is inferred from zeus's guard trips vs the lar's charge intent.
- The lar exposes **no SoC metric** (`soc_pct` is MQTT-plan-doc only), so a
  SoC-equal input check is not possible from Prometheus.

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

`JupiterShadowHarnessNoData`, `JupiterShadowLogicDivergence` (the gate),
`JupiterShadowSetpointDelta` (`values.yaml prometheusRule.setpointDeltaKw`,
default 0.5 kW), `JupiterShadowGuardConflict`.
