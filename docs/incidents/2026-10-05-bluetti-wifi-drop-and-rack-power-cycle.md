# Post-incident review — Apex 300 WiFi drop, idle evening, and the rack power cycle (cards #319, #228, #320)

**Date:** 2026-10-05 · **Severity:** high (an unplanned outage of the live
control path and the whole k3s cluster, ~7 min; 2 h 21 min without battery
telemetry; no safety exposure; cost bounded and small) · **Status:** resolved —
WiFi restored by the owner, lar v0.21.0 released the same evening; the cause of
the module drop is not established and the "battery restart = rack outage"
coupling is unchanged · **Format:** blameless SRE-style postmortem with an
A3-style summary box. All times **UTC** (local = UTC+2).

---

## A3 summary (one-box view)

| | |
|---|---|
| **Background** | The Apex 300's own WiFi/IoT module (Espressif, `192.168.50.81`) is the only path from the unit to the Bluetti cloud, and the cloud is the only path HA and the lar have for telemetry *and* commands. The homelab rack and vesta (HA) are fed from the Apex 300's AC output. Since 10-04 the lar runs 0.20.0 (placeholder rejection, #211 stale hold, #214 plausibility guard) and the integration is hand-patched so pushes arrive (see the 09-12 postmortem). |
| **Problem** | From ~16:40Z the unit's module was off the LAN; every integration reload published only the placeholder (51 % / 2008 W / 607 W) and HA showed it for 2 h. The lar's guards held PASSTHROUGH and the battery sat idle through the evening peak at ~82 %. Half an hour before the drop, the charge guard and the re-check had fought over the mode select (~350 writes in 30 min, card #228). At 18:4xZ the owner restored WiFi by restarting the unit, which cut AC output: the whole cluster and vesta rebooted. |
| **Direct cause** | Telemetry: the module left the network (pushes stopped 15:40Z, a spurious all-zero frame at 16:12Z, real values once more at 16:25Z, gone for good by 16:40Z) and the cloud had nothing fresh to serve. Outage: a full-unit restart drops the AC output that powers the rack. |
| **Root cause** | A single cloud-only path for both telemetry and command, with no local fallback (#217 / #309); and no documented WiFi-only reset on the Apex 300 — the manual's settings mode (hold AC + ECO ~2 s → P07 WiFi) was not known at the time. The cause of the module drop itself is **not established**. |
| **Countermeasures** | (1) Owner restarted the unit (fix of the moment). (2) The WiFi-only procedure recorded on #319 (hold AC power + ECO ~2 s → ECO pages to P07 WiFi → AC toggles off/on → hold both to save; idling 1 min exits *without* saving). (3) The flap and the cold-start defect fixed in lar v0.21.0 (#228, ADR-0029, released 21:30Z). |
| **Verification** | Real values back in HA at 18:46:50Z (81 %, AC-out 703 W); the lar read a real SoC at 18:45:11Z and applied DISCHARGING 0.497 kW; all six nodes Ready by ~18:49Z, no pod stuck. lar 0.21.0 on the pod since 21:32:35Z: one PASSTHROUGH write at 21:32:39Z (SoC 66 % read — the cold-start hold was not needed), one CHARGING write at 21:45:10Z; `jupiter_lar_mode_writes_total` suppressed 0. The 16:30–17:00Z flap fix has only been **replayed**, not seen live. |
| **Follow-up** | #228 part 4 (re-judge after ≥3 clean days incl. one wide-spread day); #324 (the LP wash); the rack/vesta-on-battery coupling (owner decision); `battery_freshness_mode` observe → enforce (#320); #217/#309 local path; #267; the push detector under-count. |

---

## Impact

- **Telemetry outage 16:25:49 → 18:46:50Z (2 h 21 min):** no real battery value
  reached HA. The lar planned from its last-good 82 % until the #211 stale hold
  took over at ~17:15Z (`jupiter_lar_battery_telemetry_stale = 1` from the 17:30
  sample). The evening discharge was suppressed: SoC **82 % at 16:25 → 81 % at
  18:46** — the battery did nothing. The plan at the time called for a net
  ~0.42–0.5 kW discharge; ~2 h of that is ≈1 kWh, i.e. roughly €0.1–0.3 at the
  day's spread (estimate, not measured).
- **The reported savings counter is contaminated:** `jupiter_savings_today_eur`
  stepped from ≈€0.00 to **−€0.31** between the 16:30 and 16:45Z samples and
  closed the day at −€0.14 (10-04 closed at +€0.90; the prior fortnight ran
  €0.47–1.27/day). The reporting service's inputs in that window include the
  16:12Z all-zero frame and the 2008 W placeholder from 16:40Z, so the negative
  figure is an upper bound on the loss, not a measurement.
- **~350 mode select writes in 30 min (16:30 → 17:00:10Z):** PASSTHROUGH /
  DISCHARGING alternating every poll (card #228). How many reached the unit
  after its module dropped (~16:40Z) is unknown; wear on the command path, no
  energy consequence visible in the archive.
- **Cluster outage ~18:42 → ~18:49Z:** all six nodes power-cycled (node_exporter
  boot times 18:42:07–18:42:13Z); 108 containers restarted (orchestrator, from
  kubectl at the time); the lar container exited 255; Prometheus itself was
  down (scrape gap ~18:42 → 18:48Z); vesta/HA restarted (404 "Entity not found"
  / 400 on its first calls). No pod stuck afterwards; data integrity of the
  stateful workloads after the hard power cut was not separately verified.
- **49 s of unwanted CHARGING 1.7 kW at the evening peak (18:44:22 → 18:45:11Z)**
  on the lar's cold start with no last-good SoC (≈0.02 kWh, <€0.01).
- **Evidence loss:** the lar's logs for the whole day died with the pod; this
  review rests on Prometheus, the HA archive in InfluxDB and the card comments.
- **Safety exposure:** none from the controller — every unusable reading
  degraded to a hold. The availability exposure is physical: a restart of the
  battery is a restart of the rack.

## Timeline (2026-10-05, UTC)

| Time | Event |
|---|---|
| 00:40 → 12:28 | Six integration reloads in 21 h; pushes arriving on their own all day — the 10-04 patch holds. |
| 15:02:24 | Last normal push before the trouble (SoC 77 %, grid-in 1 620 W: the battery is charging on plan). |
| 15:15:06 | Force-refresh reload (values unchanged >10 min). The placeholder stands **126 s** (51 % / 2008 W / 607 W until real 78 % at 15:17:12). lar 0.20.0 rejects it: PASSTHROUGH hold for that cycle, planned from last-good 76 % (`placeholder_rejected_total{consumer="soc"}` 0 → 1). |
| 15:17 → 15:40 | Pushes flowing (15:22, 15:33, 15:35, 15:38, 15:39). 15:39:07 last `bluetti_last_push_update`; **15:40:13 last pushed value.** |
| 15:55:06, 16:10:06 | Reloads; each publishes the placeholder for <0.5 s, then real values (80 % / 1 670 W; 81 % / 1 656 W). The push channel is dead again, the fetch still works. |
| 16:10:05 | `binary_sensor.bluetti_push_dead` on (30-min threshold). |
| 16:12:03 | The integration serves **all zeros** (SoC 0, 0 W, 0 W) — the known "IoT-module crash → spurious 0" signature. `jupiter_lar_soc_pct` reads 0 at the 16:30 Prometheus sample; the #214 guard holds PASSTHROUGH 16:15–16:30. |
| 16:25:05 | Reload → placeholder → real **82 % / 620 W / 619 W**; 16:25:49 the last real values before the outage (625 / 630 W). |
| 16:30:12, 16:45:12 | Plans `Optimal slot0 charge=2.200kW discharge=2.621kW` — both flows in one slot (the #84 peak-incentive LP wash, net −0.42 kW). Controller applies DISCHARGING 2.62 kW; the charge guard trips on every 10 s poll (`charge guard TRIP … PASSTHROUGH`); the re-check writes DISCHARGING back. ≈175 + 175 select writes until 17:00:10. Prometheus: `jupiter_lar_target_charge_kw = 2.2` with `target_discharge_kw > 0` on every sample 16:35 → 17:00. The flap ran on the plausible last-good 82 %. → **card #228 / ADR-0029**, not re-analysed here. |
| ~16:40 | The module drops for good. **16:40:35** reload → placeholder, and it never clears: no real fetch lands. |
| 16:55:30, 18:00:30 | Reloads on the episode's hourly cadence re-publish the placeholder. HA shows 51 % / 2008 W / 607 W. |
| ~17:15 | #211 stale hold (telemetry >900 s) → PASSTHROUGH; evening discharge suppressed. The planner never took 51 % or 0 % (last-good 82 %; `jupiter_lar_soc_pct` 82). Counters by 18:30: placeholder rejected soc 1 / spike_sample 18 / measured_mode 19 / house_load 1; observe-mode freshness disagreements 1 521. |
| 18:15 → 18:38 | Day-after check finds the failing fetch (not the handler bug, the patch cannot help); the owner's phone app reaches the unit over Bluetooth but not WiFi; a LAN sweep finds `192.168.50.81` dead and its MAC (`00-4b-12-31-65-6c`) in no ARP entry under any IP while the router, mesh node, vesta and other 2.4 GHz clients answer. **It is the unit, not the WiFi.** |
| 18:4x | Owner restarts the Apex 300 to recover its WiFi. AC output drops: node_exporter reports boot at **18:42:07–18:42:13Z** on all six nodes; container terminations are stamped 18:43:24Z (orchestrator); 108 containers restart; HA restarts. |
| 18:44:00 | lar cold start: `SoC read failed and no last-good; using safe default soc_min 10.0%` → plan `charge=1.703kW` (cost 40.66) → `applied live: CHARGING` at 18:44:22 — at the evening peak with the real battery at ~81 %. |
| 18:45:11 | Next cycle reads a real SoC → plan `discharge=0.497kW` → DISCHARGING. The unwanted charge lasted 49 s. |
| 18:46:50 | First real HA values in the archive since 16:25:49 (81 %, AC-out 703 W). 18:48: observe-mode log shows the feed "demonstrably ALIVE" (values changing by push). |
| ~18:49 | All six nodes Ready, no pod stuck. Recovery logged on #319 together with the WiFi-only procedure. |
| 18:49 | The cold-start defect filed on #228; 18:54 owner: "spawn hephaestus for 228". |
| 19:22 | clio's #228 part 1 (critical-load overlap soak) merged — gitops #447; the union flip is not the root of the churn. |
| 20:07 | hephaestus: jupiter PR #139 (ADR-0029). Replay of 16:30–17:00 from recorded inputs: 1 write (was >300); cold start 18:44: PASSTHROUGH, then DISCHARGING once 80 % is read. |
| 20:25 | Owner decisions recorded in ADR-0029 (LP wash → #324; guard PASSTHROUGH accepted; non-Optimal plans acted on + alerted; guard hold does not block DISCHARGING). gitops #448: nine `jupiter-tervuren-mode-writes` alert rules. |
| 20:38 | jupiter #139 → develop (768c853); gitops #448 → develop (963284c). |
| 21:30 | **Released:** jupiter v0.21.0 (tag 00205e9, release PR #140/#141), gitops #449 + release #451 → master f33616e. lar on `jupiter-lar:0.21.0` since 21:32:35Z; images built locally for arm64 (GitHub Actions outage). Changelog jupiter #143. |
| 21:32:39 / 21:45:10 | Cycle 1: SoC 66 % read, plan Optimal, one PASSTHROUGH write. Cycle 2: one CHARGING write (1.324 kW). Suppressed 0, both-flows 0, `soc_unknown` 0. |

## Causal chain (5-whys)

1. **Why did the battery sit idle through the evening peak?** No usable
   telemetry after 16:25:49Z: the placeholder guard discarded every reload
   snapshot and the #211 stale hold took over at ~17:15Z. Both are *correct*
   behaviour on an unknown battery state.
2. **Why no telemetry?** The unit's WiFi/IoT module left the LAN (~16:40Z);
   with the device offline the cloud had nothing fresh, so HA's only fetch (at
   reload) returned the placeholder.
3. **Why did the module drop?** **Not established.** The signature — pushes
   stop 15:40, spurious all-zero at 16:12, back at 16:25, gone at 16:40 — is
   the module's known crash pattern. The ~350 select commands the cloud relayed
   to it from 16:30Z are a temporal correlation only (see "unverified").
4. **Why did restoring WiFi take the rack down?** The rack and vesta hang off
   the Apex 300's AC output, and the owner restarted the whole unit because the
   manual documents no dedicated WiFi-reset combination; the settings-mode
   route to P07 was found afterwards.
5. **Why did the lar charge 1.7 kW for 49 s after the reboot?** With no
   last-good SoC the planner substituted `soc_min` (10 %) as the battery state,
   produced a feasible charge plan and the controller actuated it. An
   "unknown" that was treated as a number instead of a hold — fixed in 0.21.0
   (ADR-0029 D).

**Aggravating factors:** the #228 flap in the same half hour (two writers on
one select, a degenerate LP optimum — long-standing: ~300 min of both-flow
plans in the 13 days before, flapping unknown because logs are gone); Prometheus
and the lar's logs died in the same power cut; nothing paged anyone during the
2 h placeholder episode (jupiter alerts route to null, #250; whether the
self-heal's 30-min escalation push reached the phone is unverified).

## Resolution — what was deployed

1. **Physical (fix of the moment):** the owner restarted the Apex 300; WiFi,
   cloud, HA and the lar recovered on their own within ~4 min of power return.
   Not a permanent fix — the drop is unexplained and may recur.
2. **Procedure (permanent, needs a runbook home):** WiFi-only restart via the
   unit's settings mode — hold AC power + ECO ~2 s → ECO steps through the
   pages → **P07 = WiFi** (P06 = Bluetooth) → AC power toggles the value off,
   then on → hold both again to save/exit; idling 1 min exits **without**
   saving. Recorded on #319; the AC output is not interrupted.
3. **lar v0.21.0 (#228, ADR-0029; jupiter PR #139, release #140/#141, tag
   00205e9; gitops #448 alerts, #449 values, release #451 → master f33616e;
   changelog #143):** (A) slot 0 netted to one direction before actuation
   (`plan.net_slot0`, `packages/dispatch` untouched); (B) the charge guard
   writes no hold while the last commanded mode is DISCHARGING; (C) churn guard
   on plan/re-check writes — `control.min_dwell_seconds: 120`,
   `max_writes_per_window: 6` per `write_window_seconds: 900` (safety / guard /
   spike writes exempt); (D) unknown SoC at cold start → PASSTHROUGH hold until
   a real SoC is read; (E) metrics `jupiter_lar_mode_writes_total{mode,source}`,
   `…_suppressed_total{reason}`, `jupiter_lar_soc_unknown`,
   `jupiter_lar_plan_simultaneous_flows_total`, `jupiter_lar_plan_optimal`,
   `jupiter_lar_plan_cost_delta_eur` (note: `jupiter_lar_target_charge_kw` /
   `_discharge_kw` now carry the net); nine PrometheusRules in group
   `jupiter-tervuren-mode-writes`. Release only on the owner's "release"; the
   lar and forecast images were built locally for arm64 because the tag's CI
   job never ran (GitHub Actions outage).
4. **Already live and load-bearing (10-04):** lar 0.20.0's placeholder guard
   and observe-mode freshness (#320, ADR-0028), the #214 guard, the #211 hold,
   `bluetti_selfheal` 1.2.0's `push_dead` detector and hourly episode cadence.

Reverted: nothing.

## What held / what did not

**Held:** the placeholder guard (the 15:15 snapshot rejected; 18 spike samples
and 19 measured-mode reads discarded over the day); the #214 guard on the 16:12
all-zero frame; the #211 stale hold from ~17:15; the last-good SoC (82 %) was
never replaced by 51 or 0; `bluetti_push_dead` flagged the dead channel at
16:10; the self-heal fell back to hourly reloads instead of hammering; the
cluster came back by itself in ~7 min with no stuck pod; the lar re-applied a
sane plan one cycle after reading a real SoC.

**Did not:** two writers fought over the select for 30 min (#228); the
cold-start planner actuated on an assumed 10 % (#228); the recovery route cut
power to everything the battery feeds; nobody was paged for a 2 h placeholder
episode; the lar's own record of the day was lost with the pod.

## What went well / what went poorly (blameless)

**Well:** the 10-04 guards were in production for less than a day and did
exactly what they were built for; the diagnosis went from "failing fetch" to
"the unit's module is off the LAN" in 20 minutes using HA, the archive and a
LAN sweep, before any cluster-side change was attempted; the owner's "Bluetooth
works, WiFi does not" observation pinpointed the layer; the flap and the
cold-start defect were root-caused, replayed to four decimals, decided by the
owner and released the same evening; the InfluxDB archive carried the evidence
the pod could not.

**Poorly — lessons:**
- **L1:** The rack and vesta are downstream of the battery's AC output, so a
  battery restart is a homelab outage. *Know the power topology before
  restarting anything on it; document the WiFi-only procedure where the
  on-call hand will find it, and decide whether the rack should stay on the
  battery's output at all.*
- **L2:** The cloud path is a single point of failure for telemetry *and*
  command; a local path (BLE #217, Modbus TCP #309) would have kept the
  evening. *Keep the local control path moving.*
- **L3:** "Unknown" must mean hold. *`soc_min` keeps the LP feasible; it is
  never a battery state to actuate on (ADR-0029 D).*
- **L4:** One select, three writers (plan, guard, re-check) and no budget: a
  degenerate LP optimum turned into 350 commands in 30 min. *One arbiter per
  actuator, a dwell time, a write budget, and a counter that pages (ADR-0029).*
- **L5:** The decision record died with the pod. *Lar decisions belong in the
  archive, not only in the pod log (the #290 telemetry-archive platform half
  merged 10-06; the lar's writer is the next step).*

## Action items

- [x] WiFi restored by the owner (18:4xZ); diagnosis + the WiFi-only procedure recorded on #319
- [x] lar v0.21.0 released + deployed 21:30Z (jupiter #139/#140/#141/#143, gitops #448/#449/#451); ADR-0029
- [x] #228 part 1 (critical-load overlap soak) — gitops #447
- [ ] #228 part 4: re-judge after ≥3 clean days including one wide-spread day; the 16:30–17:00Z fix has only been replayed (clio / owner)
- [ ] #324: stop the LP planning the wash (pay the #84 incentive on net discharge); #323: trainer/writer guard
- [ ] Runbook: the WiFi-only restart procedure + "a unit restart power-cycles the rack and vesta" into `home-assitant/bluetti-selfheal.md` or the jupiter ops notes (hestia / owner)
- [ ] Power topology: keep the rack and vesta on the Apex 300's AC output, or move them to a UPS/bypass (owner decision; uncarded)
- [ ] Verify whether the self-heal 1.1.0 escalation push reached the phone during the 16:40 → 18:46Z episode (hestia)
- [ ] `battery_freshness_mode` observe → enforce after observe data across a charge start/stop (#320 follow-up, owner-gated)
- [ ] #217 / #309: a local telemetry + control path — priority bump suggested by this incident
- [ ] Reporting: how `jupiter_savings_today_eur` treats all-zero / placeholder inputs (the −€0.31 step at 16:45Z and a −€0.57 single-sample blip at 12:45Z are unexplained) (hephaestus)
- [ ] Post-power-cut integrity check of the stateful workloads (Longhorn volumes, CNPG, InfluxDB) — "no pod stuck" is not "no data lost" (atlas)
- [ ] #267 (optional `ac` read), #250 (jupiter alert routing) — unchanged, both would have mattered here
- [ ] Push detector under-count (self-heal 1.2.0, hestia) — see the 09-12 postmortem

## Unverified

- The cause of the module drop. The ~350 relayed select commands from 16:30Z
  precede the final drop by ~10 min — correlation only; the module's known crash
  signature (all-zero at 16:12Z) started before the flap.
- Which of the 16:30–17:00Z select writes reached the unit.
- The exact instant of the power cut: node boot times say 18:42:07–18:42:13Z
  (node_exporter `node_boot_time_seconds`, possibly before NTP sync), the
  container terminations are stamped 18:43:24Z.
- Whether the self-heal escalation pushed to the phone; whether any stateful
  workload lost data in the hard power cut.
- The savings loss: the reporting counter is contaminated; the ≈1 kWh / €0.1–0.3
  figure is an estimate from the plan, not a measurement.

## Evidence (reproducible)

- Prometheus (`svc/kube-prometheus-stack-prometheus`, all `queryType: range`
  unless noted): `jupiter_lar_soc_pct`, `jupiter_lar_battery_telemetry_stale`,
  `jupiter_lar_live_actuating` 10-05 14:00 → 22:00Z step 900;
  `jupiter_savings_today_eur` 12:00 → 23:59Z step 900;
  `jupiter_lar_target_charge_kw > 0 and jupiter_lar_target_discharge_kw > 0`
  15:00 → 18:00Z step 300; `sum by (consumer)
  (jupiter_lar_battery_placeholder_rejected_total)` 14:00 → 19:00Z step 1800;
  `node_boot_time_seconds` instant at 20:00Z; `up{job="jupiter-cell"}` 18:30 →
  19:00Z step 60; `max(jupiter_savings_today_eur)` 09-21 → 10-05 at 21:50Z step
  86400.
- HA archive, InfluxDB bucket `homeassistant` (read-only `influx query` in
  `influxdb-influxdb2-0`): entities `office_buzzbrick_battery_level`,
  `office_buzzbrick_ap3002532000565690_grid_input_power`,
  `…_alternating_current_out_power`, field `value`, 10-05 15:00 → 19:00Z, all
  samples (the 15:15:06 / 15:55:06 / 16:10:06 / 16:25:05 / 16:40:35 / 16:55:35 /
  18:00:35 placeholders, the 16:12:03 zeros, the 18:46:50 recovery).
- Trello #228 (`6a6caded3baa30905d2a8fc0`), #319 (`6ac23c01627490ba21ed1b6f`),
  #320 (`6ac26fc4d23758db623c7ff9`), #306, #267 comments; jupiter
  `docs/adr/0029-mode-write-discipline.md`.

## References

jupiter PRs #139 (lar mode-write discipline), #140/#141 (release v0.21.0),
#142 (master back-merge), #143 (changelog) · gitops PRs #447 (overlap soak),
#448 (alert rules), #449 (lar + forecast 0.21.0), #451 (release) · cards #228
#319 #320 #306 #267 #324 #323 #217 #309 #250 #84 · ADR-0028, ADR-0029 ·
soak `docs/soaks/2026-10-05-critical-load-overlap-soak.md` · related:
`2026-09-12-bluetti-all-zero-freeze-and-reload-only-values.md`,
`2026-08-31-bluetti-staleness-deadlock.md`
