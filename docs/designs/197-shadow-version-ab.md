# Design: repurpose the shadow slot for version A/B (lar-vNext vs live)

- **Card:** [#197](https://trello.com/c/iapvXyke) — *shadow: repurpose the shadow slot for version A/B — inputs pinned by construction*
- **Status:** DESIGN ONLY. No manifests, no chart edits, no controller code. This
  document makes the change shovel-ready for when zeus retires (#169, ~Aug); the
  build is a separate implementation card (or cards).
- **Author:** Atlas (cluster/GitOps)
- **Date:** 2026-07-19
- **Related:** #141 (shadow harness), #196 (why the current comparison is void),
  #192 (`JupiterControllersDoubleLive` backstop), #155/#151 (single-controller
  interlock), #169 (zeus decommission — frees the slot), #147 (fine-grained
  inputs equality).

---

## 1. Executive summary

The `jupiter-shadow` harness (`landingzones/jupiter-shadow/`) today joins two
*different codebases on different feeds*: A = the live lar (`variant`-less
`jupiter_lar_*`, `site_id=tervuren`, actuates) and B = zeus (`zeus_*`, demoted,
`zeus_commander=0`, never actuates). That is not a controlled experiment.
`jupiter_shadow_logic_divergence = jupiter_shadow_divergence *
jupiter_shadow_inputs_source_match`, and #196 proved `inputs_source_match` has
been **0 for the entire life of the series** (zeus on `price_source=4 partial` /
`forecast=1 fallback`, lar on primary), so the gate is structurally pinned to 0
and carries no information. ~15% raw intent divergence is 100% absorbed into the
"benign" `inputs_divergence` bucket.

**Proposal:** replace zeus in the shadow slot with **lar-vNext** — the *same
image family* as live, `control.enabled=false`, pointed at the *same* in-cluster
price/forecast services. Then `inputs_source_match = 1` **by construction** and
any divergence is attributable to the **version**. That is a real A/B, and it is
what the harness is for after zeus is gone.

This is **not a config flip.** Three hard problems must be solved first — metric
label collision, #192 interference, and provable non-actuation — plus a
pre-defined ship criterion so the result cannot become another
green-number-that-means-nothing (#196/#181). All three are resolved concretely
below.

The single most important guardrail in this doc: **the load-bearing
non-actuation gate is at the Cilium network layer (L7), not in `values.yaml`**,
because a future `values.yaml` edit that flips `controller: live` must remain
physically incapable of touching the battery.

---

## 2. What is actually there today (grounding)

### 2.1 The live lar (`landingzones/jupiter-tervuren/`)

- `Deployment/jupiter-cell`, `replicas: 1`, `strategy: Recreate`
  (`templates/deployment.yaml`). `SITE_ID=tervuren`, `CELL_CONTROLLER=shadow`
  env as belt-and-braces, but the mounted site-config (`siteConfig.controller:
  live`, `control.enabled: true`) is authoritative and the pod is **the sole
  live actuator** today.
- **Actuation path = Home Assistant REST write.** `siteConfig.control.mode:
  working_mode` writes `select.apex300_working_mode` via HA at
  `http://vesta.local:8123` (**plaintext HTTP**, `192.168.50.18:8123`). An HA
  service call is `POST /api/services/select/select_option`; an HA read is `GET
  /api/states/<entity>`. This GET/POST split is what makes an L7 gate possible
  (see §5).
- **The #155 interlock** gates every command on a fresh MQTT
  `zeus/tervuren/commander == 0` read; the lar refuses (safe-holds) on
  `commander==1`, stale, or unknown. It is app logic in
  `services/lar/jupiter_lar/interlock.py`.
- **Metrics** (all `jupiter_lar_*`, `site_id=tervuren`, no `variant` label
  today; scraped by `ServiceMonitor/jupiter-cell` with **no
  metricRelabelings**): `jupiter_lar_target_charge_kw`,
  `_target_discharge_kw`, `jupiter_lar_price_source` (0=primary 1=cache 2=none),
  `jupiter_lar_forecast_source`, `jupiter_lar_soc_pct`,
  `jupiter_lar_control_available`, `jupiter_lar_actual_mode`,
  `jupiter_lar_ha_read_ok` / `_ha_read_errors_total`, `jupiter_lar_spike_*`, and
  the two interlock series the fleet check keys on: **`jupiter_controllers_live`**
  (the lar's own count of controllers it believes command its site) and
  **`jupiter_lar_live_actuating`** (1 iff it issued a live command this cycle).
  The reporting-service separately exposes `jupiter_reporting_*` (incl.
  `jupiter_reporting_capacity_peak_kw` from the live plan doc).

### 2.2 The shadow harness (`landingzones/jupiter-shadow/`)

Monitoring-only: a `PrometheusRule` of `jupiter_shadow_*` recording rules that
`label_replace` zeus terms with `site_id=tervuren` and join `on(site_id)`
against the `site_id`-labelled `jupiter_lar_*` terms, plus a dashboard
(`jupiter-shadow-parity`) and the separate `gate-blind-prometheusrule.yaml`
(#196). The gate signal:

```
jupiter_shadow_logic_divergence = jupiter_shadow_divergence
                                * on(site_id) jupiter_shadow_inputs_source_match
```

### 2.3 The #192 fleet interlock (`landingzones/jupiter-central/templates/interlock-prometheusrule.yaml`)

```
alert: JupiterControllersDoubleLive
expr: |
  (
    max by (site_id) (jupiter_controllers_live) > 1
  )
  or
  (
    (max by (site_id) (zeus_commander) == 1)
    and on (site_id)
    (max by (site_id) (jupiter_lar_live_actuating) == 1)
  )
severity: critical
```

This is the machine backstop for HARD INVARIANT #1 (exactly one live controller
per battery). Clause 1 is the lar's own count; clause 2 is the cross-stack
zeus-vs-lar race the count can miss.

### 2.4 Consumers that select bare `jupiter_lar_*` / interlock series (the blast radius of adding a label)

Any selector written as `jupiter_lar_x` (no label matcher) matches **every**
series named `jupiter_lar_x` regardless of extra labels — so introducing a
second lar with only an added `variant` label makes these return **two** series
and breaks `on(site_id)` joins (many-to-one) and `max by(site_id)`
aggregations. The complete set of files that must be updated in lockstep:

| File | Series it selects |
| --- | --- |
| `landingzones/jupiter-central/templates/interlock-prometheusrule.yaml` (#192) | `jupiter_controllers_live`, `jupiter_lar_live_actuating` |
| `landingzones/jupiter-shadow/templates/prometheusrule.yaml` | `jupiter_lar_target_charge_kw`, `_target_discharge_kw`, `jupiter_lar_price_source`, `jupiter_lar_forecast_source`, `jupiter_lar_soc_pct`, `jupiter_charge_guard_trips_total` |
| `landingzones/jupiter-shadow/templates/gate-blind-prometheusrule.yaml` (#196) | (reads `jupiter_shadow_inputs_source_match`; retires with zeus — see §8) |
| `landingzones/jupiter-tervuren/templates/prometheusrule.yaml` | `jupiter_lar_ha_read_errors_total` (capacity-peak read alert) |
| `landingzones/jupiter-central/dashboards/jupiter-reporting-validation.json` | `jupiter_lar_*` panels |
| `landingzones/jupiter-shadow/dashboards/jupiter-shadow-parity.json` | `jupiter_lar_*` panels |

---

## 3. The A/B, in one picture

```
        price-service ─┐        (identical in-cluster HTTP source)
                       ├─► lar  A  = variant="live"   →  ACTUATES HA  (sole commander)
      forecast-service ┘         \
                                  ├─ jupiter_shadow_* join on(site_id) → divergence attributable to VERSION
        price-service ─┐         /
                       ├─► lar  B  = variant="shadow" →  CANNOT actuate (L7-gated)
      forecast-service ┘        (same image family, control.enabled=false, vNext tag)
```

Because both variants pull price/forecast from the *same* services,
`jupiter_shadow_inputs_source_match = 1` by construction and (once SoC/peak are
pinned, §6.1) `jupiter_shadow_inputs_divergence ≈ 0`. Divergence that remains is
the version delta — the thing we want to measure.

---

## 4. Problem 1 — metric label collision

### Resolution (one sentence)
Stamp a **`variant` label** on every lar series **at the ServiceMonitor scrape**
(gitops-owned relabeling, no app change): the live lar gets `variant="live"`, the
shadow lar-vNext gets `variant="shadow"`; then pin every existing consumer to
`{variant="live"}` and repoint the shadow harness join from `zeus_* vs lar` to
`lar{variant="live"} vs lar{variant="shadow"}`.

### Detail

**Why a `variant` label and not a distinct `site_id`.** A distinct `site_id`
(e.g. `tervuren-shadow`) would silently exclude the shadow from every
`by (site_id)` fleet rule — including #192 — which is *exactly the invariant we
must not weaken by accident*. Keeping `site_id=tervuren` on both and
distinguishing with an explicit `variant` label forces every rule author to make
an intentional choice about whether a rule is variant-scoped, and keeps the two
variants joinable `on(site_id)` for the A/B. So: **same `site_id`, new
`variant`.**

**Where the label comes from — scrape-time relabeling, not app code.** Add to
each lar's ServiceMonitor:

```yaml
# jupiter-tervuren ServiceMonitor (live)
metricRelabelings:
  - targetLabel: variant
    replacement: live
# shadow lar ServiceMonitor
metricRelabelings:
  - targetLabel: variant
    replacement: shadow
```

This is deterministic, lives entirely in gitops (Atlas' domain), needs **no
change to the lar image**, and cannot be spoofed by the workload. (If the vNext
image later self-labels a `variant`, honor the app value and drop the
relabeling — but the default design assumes no app change.)

**Series affected & the exact edit.** Every consumer in §2.4 is pinned to
`{variant="live"}` so its meaning is unchanged the instant the shadow appears:

- Shadow harness recording rules become a **live-vs-shadow** join. The "zeus"
  side (`jupiter_shadow_zeus_*`) is replaced by the shadow lar:
  - `jupiter_shadow_zeus_intent_code` → derived from
    `jupiter_lar_target_{charge,discharge}_kw{variant="shadow"}` (no more
    `label_replace`; the shadow already carries `site_id`).
  - the "cell" side (`jupiter_shadow_cell_*`) pins `{variant="live"}`.
  - The join stays `on(site_id)` but now both operands live in ns
    `jupiter-tervuren`, `site_id=tervuren`, distinguished by `variant`.
  - Series names are kept (a divergence is a divergence); only the inputs
    change. Optionally rename `_zeus_` → `_shadow_variant_` in a follow-up for
    clarity, but keeping names minimizes dashboard churn.
- `jupiter_charge_guard_trips_total{site_id="tervuren"}` → add `variant="live"`
  (the guard veto that matters is the live one).
- `jupiter-tervuren` capacity-peak alert: pin `jupiter_lar_ha_read_errors_total`
  to `{variant="live"}`.
- Both dashboards: add a `variant` template variable (default `live`) and pin
  panel queries; add shadow overlays on the parity dashboard.

**Failure mode to avoid:** shipping the relabeling before the consumers are
pinned would break the live #192 join the moment a second series appears. The
implementation card MUST land the `{variant="live"}` pins **in the same release**
as (or before) the shadow deploy. This is called out again in §7.

---

## 5. Problem 2 — do not trip #192, do not weaken it

### Resolution (one sentence)
Narrow the DoubleLive count to `variant="live"` **and** add a strictly-new,
unconditional `JupiterShadowActuated` alarm on `variant="shadow"` — so the shadow
is excluded from the count precisely because it is provably non-actuating (§6),
while shadow-actuation is now caught *directly* (no longer dependent on zeus
commanding), making total coverage **stronger**, not weaker.

### The exact new expressions

```yaml
# jupiter-central/templates/interlock-prometheusrule.yaml (#192), REVISED
- alert: JupiterControllersDoubleLive
  expr: |
    (
      max by (site_id) (jupiter_controllers_live{variant="live"}) > 1
    )
    or
    (
      (max by (site_id) (zeus_commander) == 1)
      and on (site_id)
      (max by (site_id) (jupiter_lar_live_actuating{variant="live"}) == 1)
    )
  for: {{ .Values.fleetInterlock.for }}
  labels: { severity: critical }

# NEW, in the same rule group — the shadow tripwire
- alert: JupiterShadowActuated
  # A variant="shadow" lar reported issuing a live command. This must NEVER
  # happen: the shadow is L7-gated out of the actuation path (design #197 §6).
  # Fires unconditionally — it does not need zeus to be commanding.
  expr: max by (site_id) (jupiter_lar_live_actuating{variant="shadow"}) == 1
  for: 0m
  labels: { severity: critical }
  annotations:
    summary: a SHADOW lar reported live actuation (invariant/gate breach)
    description: >-
      Site {{ $labels.site_id }}: a variant="shadow" lar set
      jupiter_lar_live_actuating=1 — it believes it issued a battery command.
      The shadow is constructed to be physically incapable of actuation (L7
      GET-only egress to HA, no command creds). A 1 here means either that gate
      failed OR a series is mislabeled. Treat as a live-safety incident: confirm
      the battery working-mode entity, and scale the shadow to 0 immediately.
```

### Why the invariant still holds (the argument the card asks for)

- **Coverage is a superset, not a subset.** Old #192 fired on the shadow only
  *incidentally* — via clause 2, and only if zeus happened to be commanding, or
  via the count if the shadow counted itself. New #192 keeps the real
  double-live cases (two `variant="live"` actuators → count > 1; zeus + live lar
  → clause 2) **and** adds `JupiterShadowActuated`, which fires on the shadow
  actuating **unconditionally**. Union(new DoubleLive, ShadowActuated) ⊇ old
  DoubleLive for every state. So the change is strictly *tighter*.
- **The narrowing is safe because `variant="shadow"` is trustworthy by
  construction.** Excluding `variant="shadow"` from the count is only sound if a
  `variant="shadow"` series can never represent a real actuator. That is
  guaranteed by §6: the shadow physically cannot reach the HA write path, so
  `variant="shadow"` ⟺ non-actuating. The label is scrape-injected by gitops
  (§4), not self-asserted by the workload, so it cannot be spoofed.
- **Two independent lines of defense on the same event.** If a future editor
  wrongly gives the shadow a `variant="live"` ServiceMonitor, the count clause
  catches it (2 live). If the shadow keeps `variant="shadow"` but somehow
  actuates, `JupiterShadowActuated` catches it. Neither hole is left open.

---

## 6. Problem 3 — provable non-actuation (safety-critical)

### Resolution (one sentence)
Make actuation **physically impossible at the Cilium L7 layer** — the shadow's
own CiliumNetworkPolicy permits only HTTP `GET` to `vesta:8123` (reads) and no
route by which an HA service-call `POST` can leave the pod — so no `values.yaml`
edit (even `controller: live`) can actuate; pin that gate with a
`helm template` CI assertion **and** a runtime deny-probe.

### The threat model

The lar actuates by `POST`ing an HA service call to `vesta.local:8123`. Every
config-level guard the current chart relies on is defeatable by a single
`values.yaml` edit or a code regression:

- `CELL_CONTROLLER=shadow` env — overridden by the mounted site-config.
- `siteConfig.controller: shadow` / `control.enabled: false` — a one-line flip.
- "the image refuses to run `live`" — **true only of 0.4.0**; the current live
  image is 0.13.2 and runs `live`, and **vNext will support `live` too** (that is
  the point of A/B-ing it). So this cannot be relied on.
- the #155 interlock refusing on missing commander — app logic, defeatable by a
  bug.

None of these is a *hard* gate. The design therefore puts the load-bearing gate
where a controller flip cannot reach it: the network.

### The gate — layered, load-bearing layer first

1. **(LOAD-BEARING) L7 CiliumNetworkPolicy: GET-only to HA.** The shadow gets its
   *own* CiliumNetworkPolicy with an **egress default-deny** (this is the one
   place we deliberately ship egress lockdown — justified because severing the
   shadow's egress is harmless: it actuates nothing and its loss is not a live
   regression) admitting only: cluster DNS; the in-cluster price/forecast
   services; the OTLP collector; and HA reads via an **L7 HTTP rule restricted to
   `method: GET`** on the read paths. HA is plaintext HTTP, so Cilium's Envoy
   proxy sees the method and **drops any `POST`** (the service-call verb) before
   it leaves the pod. Sketch:

   ```yaml
   egress:
     - toEndpoints: [ {matchLabels: {k8s:k8s-app: kube-dns, k8s:io.kubernetes.pod.namespace: kube-system}} ]
       toPorts: [ {ports: [{port: "53", protocol: UDP}, {port: "53", protocol: TCP}]} ]
     - toEndpoints: [ {matchLabels: {k8s:io.kubernetes.pod.namespace: jupiter-central}} ]
       toPorts: [ {ports: [{port: "8080", protocol: TCP}]} ]
     - toEndpoints: [ {matchLabels: {k8s:io.kubernetes.pod.namespace: jaeger}} ]
       toPorts: [ {ports: [{port: "4317", protocol: TCP}]} ]
     - toCIDR: [ 192.168.50.18/32 ]          # vesta / HA
       toPorts:
         - ports: [ {port: "8123", protocol: TCP} ]
           rules:
             http:
               - method: "GET"               # reads ONLY; POST service-calls are dropped by the proxy
   ```

   Critically, this policy is a **separate object from the controller config**:
   flipping `controller: live` in the shadow's values does not remove the L7
   rule, so a live-mode shadow would compute a plan and then have its actuation
   `POST` dropped at the proxy. This is the "hard gate a future edit cannot flip"
   the card asks for.

   > Caveat to verify at build time: Cilium L7 HTTP policy requires the Envoy
   > proxy path and plaintext HTTP (satisfied — HA is `http://`). The impl card
   > MUST confirm on the live arm64 Cilium 1.16 that the GET-only rule admits
   > `GET /api/states/...` and denies `POST /api/services/...` via a Hubble flow
   > check before the shadow is trusted. If for any reason L7 cannot be enforced
   > on this cluster, fall back to option (1b).

   **(1b) fallback — no HA egress at all.** If L7 cannot be relied on, the
   shadow gets *zero* HA egress and sources SoC/peak from the injected plan doc
   (§6.1). Then there is no HA path to actuate, full stop. This is actually the
   *stronger* option and is the recommended target end-state (§6.1).

2. **(belt-and-braces) No actuation credentials.** The shadow's SealedSecret
   omits any HA write-capable token and any MQTT command/commander creds. Its
   EMQX user (if it publishes telemetry at all) has no ACL on the command topic
   and no subscribe on `zeus/tervuren/commander`; without the commander signal
   the #155 interlock reads UNKNOWN and safe-holds. (HA long-lived tokens are not
   per-scope, so this is defense-in-depth, not the load-bearing gate — hence the
   L7 layer above.)

3. **(belt-and-braces) Config defaults.** `controller: shadow`,
   `control.enabled: false`, `CELL_CONTROLLER=shadow`. Kept, but explicitly
   **not** trusted as the gate.

4. **(runtime tripwire) `JupiterShadowActuated`** (§5) pages the instant a
   `variant="shadow"` series reports `jupiter_lar_live_actuating=1`.

### The test that pins it (hard gate + test, not a default)

- **CI / policy test (in gitops, blocks merge):** a `helm template` assertion on
  the shadow chart that fails the build if any of these regress —
  (a) the shadow CiliumNetworkPolicy has an egress rule to `192.168.50.18/32:8123`
  **with** `rules.http` present **and** every listed method `== GET` (no `POST`,
  no method-less allow-all); (b) no egress rule reaches the MQTT command path;
  (c) `control.enabled == false` and `controller == shadow`; (d) the shadow
  secret declares no HA/command write keys. Because it is a rendered-manifest
  assertion, a `values.yaml` edit that flips the controller **or** widens the L7
  methods fails the pipeline — the gate cannot be silently flipped.
- **Runtime conformance probe (at rollout + periodic):** from the shadow pod,
  issue a `POST /api/services/select/select_option` to `vesta:8123` and assert it
  is **denied** (Cilium drop / no 2xx), and a `GET /api/states/<soc>` and assert
  it **succeeds**. Capture the Hubble flow showing the dropped `POST`. This
  proves the gate empirically, not just structurally. (Documented as a runbook
  step; it is a synthetic request, not battery actuation.)

---

## 7. What the A/B reports and its PRE-DEFINED ship criterion

> The #196/#181 failure mode we must not repeat: **a green number that validates
> nothing.** #196 = the gate was a product with a 0 multiplier, so `0` meant
> "blind", not "equal". #181 = a wedged pipeline froze a green savings figure.
> The rule below is designed so that a pass is *impossible to read off a single
> flat line*; every pass is gated on an explicit **validity precondition** and
> the raw disagreement, not the masked one.

### Per-variant signals (reuse the harness machinery, repointed to variants)

- **Intent:** `jupiter_shadow_intent_match` / `_divergence` (charge/discharge/idle).
- **Setpoint:** `jupiter_shadow_setpoint_delta_kw` and `_setpoint_abs_delta_kw`
  (|live_net − shadow_net| kW).
- **Inputs pinned check:** `jupiter_shadow_inputs_source_match` (must be 1),
  `jupiter_shadow_inputs_divergence` (must be ≈0 — see the new guard below),
  `jupiter_shadow_soc_match` / `_peak_match`.
- **Economic headline (needs a metric vNext must export):** a per-cycle
  **expected-plan-cost** gauge, e.g. `jupiter_lar_plan_expected_cost_eur`
  (the optimizer's LP objective for the current plan). *No such metric exists
  today* (confirmed: the lar exposes setpoints and sources, not the objective),
  so the economic arm is contingent on the vNext image adding it; the impl card
  owns that. The A/B then compares cumulative expected cost over the window
  per variant on identical inputs. **Fallback if the metric is not added:** the
  A/B ships on intent + setpoint parity only, plus an offline counterfactual
  cost backtest over the window (documented, not automated) — and this
  limitation is stated in the sign-off packet, never hidden.

### The new validity guard (prevents the #196 mode in the new harness)

```yaml
- alert: JupiterABInputsNotPinned
  # In the version A/B, inputs are supposed to be identical by construction.
  # If inputs_divergence is materially non-zero, the "same feeds" assumption is
  # BROKEN and the experiment is INVALID — the divergence numbers cannot be read
  # as a version delta. This is the direct successor to JupiterShadowLogicGateBlind.
  expr: max by (site_id) (avg_over_time(jupiter_shadow_inputs_divergence[1h])) > 0.02
  for: 1h
  labels: { severity: warning }
  annotations:
    summary: version A/B inputs are not pinned — result is not attributable to version
```

Note the inversion vs the old harness: with zeus, ~15% divergence hid in
`inputs_divergence` and was called *benign*. Here `inputs_divergence` **must be
≈0**; if it is not, the A/B is void. Same series, opposite expectation, and now
alerted on — so "everything filed as benign inputs" can never again pass silently.

### Ship criterion (all must hold; define the window before starting)

**Window:** 7 consecutive clean UTC days (mirrors the #164 soak discipline; any
mid-window change to *either* variant's inputs/version restarts the clock).

**Validity precondition (if any fails, the window is VOID — not a pass):**
1. `jupiter_shadow_both_present == 1` throughout.
2. `JupiterShadowLogicGateBlind` **silent** and `jupiter_shadow_inputs_source_match
   == 1` throughout (now automatic — but asserted, never assumed).
3. `JupiterABInputsNotPinned` **silent** throughout (`inputs_divergence ≈ 0`).
4. `JupiterShadowActuated` **never fired** (the shadow stayed a clean
   counterfactual).

**Pass rule (only read if the precondition held):**
1. `jupiter_shadow_logic_divergence_strict == 0` sustained — *or* every nonzero
   sample is reviewed and attributed to an **intended** vNext behavior change
   (documented per-incident, not waved off).
2. `jupiter_shadow_setpoint_abs_delta_kw` within `setpointDeltaKw` (0.5 kW) for
   the window, or each excursion explained.
3. **Economic:** cumulative expected-plan-cost delta shows vNext **not worse**
   than live by more than a pre-set band (e.g. ≤ +0.5% on identical inputs);
   any improvement is real because inputs are pinned. (Contingent on the
   `_plan_expected_cost_eur` metric; else the offline backtest, flagged.)

**Explicit anti-pattern clause:** a flat `logic_divergence = 0` is **not**
sufficient on its own. Because inputs are pinned, raw `jupiter_shadow_divergence`
≈ `logic_divergence`; the sign-off packet must show the **raw** divergence line
and the `inputs_divergence ≈ 0` proof side by side, so a masked 0 is
structurally impossible to present as a pass.

---

## 8. Rollout / rollback and #169 sequencing

### Rollout (each step gated on the prior being green)

0. Build `jupiter-lar` vNext (arm64, `--provenance=false`) — jupiter repo, its own card.
1. Land the **`variant="live"` relabeling + consumer pins** (§4) and the
   **revised #192 + `JupiterShadowActuated`** (§5) in one gitops release. This
   is inert while only the live lar exists (`variant="live"` matches exactly the
   series that exist today), so it is safe to ship ahead of the shadow.
2. Deploy the **shadow lar-vNext** landing zone: `variant="shadow"`,
   `control.enabled=false`, same price/forecast, and the **L7 non-actuation
   CiliumNetworkPolicy** (§6). Gate on: CI policy test green, runtime deny-probe
   passes, `JupiterShadowActuated` silent, `JupiterShadowLogicGateBlind` /
   `JupiterABInputsNotPinned` silent.
3. Run the N-day A/B (§7). Evaluate the ship criterion.
4. **On pass:** promote vNext to the live `jupiter-tervuren` image tag via the
   normal human-gated release (respecting any active deploy freeze — see below).
   The shadow slot then either idles or picks up the next vNext.

### Rollback

- The shadow is non-actuating by construction, so "rollback the experiment" =
  set the shadow chart `enabled: false` / scale to 0. **Zero battery impact.**
- If a *promoted* vNext (now live) misbehaves, that is the standard
  `jupiter-tervuren` `image.tag` revert — unrelated to the shadow slot.
- The §4 relabel/#192 changes are independently revertible (pins are additive).

### #169 (zeus decommission) sequencing

- **Ordering.** Do not remove zeus until the variant-based harness is in place,
  or there is a window with no shadow comparison at all. Recommended order:
  (a) close the #164 savings-parity soak; (b) land step 1 above (relabel + #192
  revision) — harmless with zeus still present; (c) decommission zeus (#169) —
  this removes `zeus_*`, so the **current** `jupiter_shadow_zeus_*` join goes
  absent (expected) and `JupiterShadowLogicGateBlind` becomes **moot** and is
  retired *with* zeus (its `values.yaml` note already says so); (d) repoint the
  harness recording rules from `zeus_*` to `jupiter_lar_*{variant="shadow"}` and
  deploy the shadow lar-vNext (steps 2–3).
- **Interaction to flag:** `JupiterShadowLogicGateBlind` (#196) is the zeus-era
  validity guard; `JupiterABInputsNotPinned` (§7) is its successor for the
  version A/B. The cutover retires one and introduces the other in the same
  release, so validity is never unguarded.
- **Freeze awareness:** the current jupiter-tervuren deploy freeze (to the #164
  sign-off) forbids anything that restarts the tervuren pod or changes the soak
  subject. Steps 1 and the shadow deploy (step 2) do **not** touch the live pod,
  but step 4 (promoting vNext to live) obviously does and is a separate,
  human-gated release outside any freeze. This design doc itself deploys nothing.

---

## 9. Open questions for the implementation card(s)

1. **Confirm Cilium 1.16 L7 GET-only enforcement** on the live arm64 cluster via
   a Hubble drop check before trusting the gate; if it cannot be enforced, adopt
   the §6.1b "no HA egress, SoC from injected plan doc" end-state (stronger).
2. **vNext must export `jupiter_lar_plan_expected_cost_eur`** (or equivalent LP
   objective) for the economic arm; otherwise the A/B is intent+setpoint parity
   + offline backtest only.
3. **SoC/peak input pinning:** decide between (a) both variants read HA (L7
   GET-only) within the `socDeltaPct`/`peakDeltaKw` bands, or (b) inject the live
   lar's SoC/peak into the shadow so inputs are byte-identical and the shadow
   needs no HA egress at all (recommended; requires a vNext input-source option).
4. Decide whether to rename `jupiter_shadow_zeus_*` recording series to
   `_shadow_variant_*` for clarity (dashboard churn) or keep names (minimal diff).
5. Owner sign-off on the exact economic band and window length in §7.

---

## 10. Summary of the three resolutions

| Problem | Resolution |
| --- | --- |
| **1. Label collision** | Scrape-time `variant="live"|"shadow"` relabel on each lar's ServiceMonitor (no app change); pin all existing consumers to `{variant="live"}`; repoint the shadow join to `lar{variant="live"}` vs `lar{variant="shadow"}`. |
| **2. #192 interference** | Narrow DoubleLive to `{variant="live"}` **and** add unconditional `JupiterShadowActuated` on `{variant="shadow"}`; coverage becomes a strict superset, and the narrowing is sound because `variant="shadow"` ⟺ non-actuating by construction (§6). |
| **3. Provable non-actuation** | Load-bearing **L7 Cilium GET-only egress to HA** (a controller flip cannot bypass it), pinned by a `helm template` CI assertion **and** a runtime POST-deny probe; config flags + missing creds + `JupiterShadowActuated` as defense-in-depth. |
