# Post-incident review — Apex 300 WiFi drop #2 and the AC-output power cut (cards #331, #319, #320, #228)

**Date:** 2026-10-07 · **Severity:** high (an unplanned outage of the live
control path and the whole k3s cluster plus vesta, ~6 min; 1 h 24 min without
battery telemetry; one controller command issued on a frozen SoC; no safety
exposure; cost small) · **Status:** mitigated — telemetry and the cluster
recovered by ~14:21Z; the cause of the module drop is still not established,
and the "rack and vesta hang off the battery's AC output" coupling that turned a
WiFi problem into an outage for the second time in 48 h is unchanged (#331) ·
**Format:** blameless SRE-style postmortem with an A3-style summary box. All
times **UTC** (local = UTC+2).

---

## A3 summary (one-box view)

| | |
|---|---|
| **Background** | The Apex 300's WiFi/IoT module (`192.168.50.81`, MAC `00-4b-12-31-65-6c`) is the only path from the unit to the Bluetti cloud, and the cloud is the only path HA and the lar have for telemetry *and* commands. The homelab rack and vesta (HA) are fed from the Apex 300's AC output. Since 10-06 17:01Z the lar runs **0.22.0** with push-aware freshness in **enforce** (#320); the HA integration is hand-patched (#319). Two days earlier (10-05) the same module dropped and the owner's full-unit restart power-cycled the rack; that review recorded a WiFi-only route through the unit's settings mode (P07) *from the manual, never rehearsed*. |
| **Problem** | From ~13:00Z the module was off the LAN again: HA's Bluetti entities went unavailable, each self-heal reload published only the placeholder (51 % / 2008 W / 607 W), the lar held its last-good 46 % and — because a spike override had latched at 12:56:52Z with no samples left to release it — kept the battery commanded to DISCHARGING for 78 min, including one write on the frozen SoC. While trying the P07 route at the front panel, a single press of the AC power button switched the AC output off: the rack and vesta lost power at ~14:15:12Z and 166 containers restarted. |
| **Direct cause** | Telemetry: the module left the network between 12:54:46Z (last real push) and 13:05:05Z (first placeholder-only reload). Outage: on the Apex 300 front panel the AC power button *alone* toggles AC output, and the rack is on that output. Controller: the #211 stale guard measures entity timestamps, and every self-heal reload re-stamps them (placeholder → unavailable), so with reloads at 13:05, 13:20, 13:40 and 14:00 the guard was armed in only one of five cycles; the latched spike override was re-applied when it cleared. |
| **Root cause** | One cloud-only path for telemetry and command with no local fallback (#217/#309); the rack and HA downstream of the device being serviced (#331); a recovery procedure copied from the manual and first exercised under incident pressure; a hold mechanism (spike override) with no release path when its input disappears. The cause of the module drop itself is **not established** — second occurrence in 48 h, so the 10-05 restart did not cure it. |
| **Countermeasures** | Nothing shipped yet. (1) Fix of the moment: AC output switched back on; the module was back on the cloud by 14:18:33Z. (2) This review amends the 10-05 record and the P07 procedure with the front-panel warning. (3) Proposed: #331 power topology (headline), the runbook + self-heal wording (hestia), the stale-guard/spike-latch defects (hephaestus), a stale-telemetry alert (atlas). |
| **Verification** | lar: real SoC 40 % read at 14:18:33Z (cold start), telemetry age 9.7 s and `stale = 0` at the 14:21:24Z scrape, plan DISCHARGING 0.29 kW applied 15:15:11Z, SoC 40 → 38 % by 15:45Z. Cluster: 6/6 nodes Ready (Ready-since unchanged), 166 containers started 14:15:26 → 14:21:10Z, no pod stuck, Longhorn 13/13 attached volumes healthy, CNPG `ceres-pg` + `jupiter-pg` healthy. The only alert the cut produced: `KubeJobFailed` (the 14:20Z `influxdb-buckets` cron run; the 18:20Z run completed). |
| **Follow-up** | #331 (move the rack + vesta off the battery's AC output — owner decision); #319 (rehearse the WiFi-only route with the rack on bypass, prefer the app's Bluetooth → Reset WiFi, child lock P08); hephaestus card for the stale-guard re-stamp defect + the spike-override latch + the #178 subtrahend after the restart; an alert on `jupiter_lar_battery_telemetry_stale`; hestia: the self-heal escalation text says "power-cycle the battery"; #217/#309; the open ARP question. |

---

## Impact

- **Telemetry outage 12:54:46 → ~14:18:33Z (1 h 24 min):** last real push at
  12:54:46Z (AC-out 468 W, grid-in 469 W; SoC 46 % since 12:44:53Z); first real
  value again at the lar's cold-start read 14:18:33Z (40 %). In between the
  lar's reads returned non-numeric states (`unavailable`/`unknown`: 424
  "grid-input unusable (no sample)" polls 13:05:05 → 14:15:11Z) with the
  placeholder triple visible only at the reload instants.
- **Spike override latched 12:56:52 → 14:15:11Z (78 min):** a real spike (HEM
  import 3.07 kW at 12:57Z) triggered DISCHARGING 2.59 kW on SoC 46 %. Release
  needs three fresh samples ≤ 1.0 kW; from 13:05:05Z there were no samples, so
  it never released. Plan intents overridden: charge 1.311 kW (13:00, 13:15),
  idle (13:30, 13:45), charge 0.260 kW (14:00). SoC fell 46 → 40 % (≈0.78 kWh)
  by 14:18Z; what the unit actually did in the gap is unobservable (the house
  import stayed 2.0–2.3 kW through 13:25–14:05Z, which does not look like a
  2.59 kW discharge being honoured).
- **One command on a frozen SoC:** 14:15:11Z `applied live: select ->
  'DISCHARGING' (discharge=2.59kW, spike override)` with the SoC frozen at 46 %
  and the feed dead for 80 min — the #211 hold had cleared at that cycle (see
  causal chain). Delivery is unknown (the module was offline; the cut followed
  one second later). Real SoC was 40 % ≥ `discharge_min_soc_pct` 20 %, so no
  hazard, but it is the guard-bypass class of defect the 10-05 review's L3
  warned about.
- **The stale hold worked for one cycle only:** 14:00:13 → 14:15:11Z.
- **Cluster + HA outage ≈14:15:12 → ~14:21:30Z:** all six nodes power-cycled
  (`node_boot_time_seconds` 14:16:23–14:16:33Z); 166 containers started between
  14:15:26 and 14:21:10Z (137 in the 14:18 minute);
  `sum(kube_pod_container_status_restarts_total)` 1 691 → 1 848; Prometheus
  scrape gap ~14:15:18 → 14:21:02Z; HA's archive writes stop 14:14:47Z and
  resume 14:21:31Z. jupiter-cell exited 255 (restart 1). No pod stuck.
- **After-restart churn:** 6 working-mode writes in 12 min (14:18:33 CHARGING,
  14:19:14 DISCHARGING spike 2.24 kW, 14:21:14 CHARGING, 14:25:35 DISCHARGING
  spike 2.33 kW, 14:27:35 CHARGING, 14:30:06 PASSTHROUGH guard trip) — exactly
  the `JupiterLarModeWriteChurn` threshold (> 6), not over it. The two spikes
  coincide with the battery being told to CHARGE (HEM import 2.26–2.33 kW
  14:26–14:31Z, then 1.0 kW) and the archive has no usable grid-input reading
  before 14:31:42Z, so the #178 correction most likely subtracted nothing and
  the battery's own charge ramp counted as a house spike. The charge guard then
  tripped on the 2.30 kW quarter mean and held PASSTHROUGH 14:30 → 14:45Z
  (plan charge 0.76 kW suppressed, ≈0.2 kWh).
- **Savings counter:** `jupiter_savings_today_eur` 0.1249 at 14:14Z → 0.1144 at
  14:32Z → 0.1277 at 16:00Z → 0.1711 at 18:43Z; the day is small and the gap
  is inside it, so the counter cannot price the incident. No measurable loss.
- **Evidence loss:** HA's InfluxDB export drops writes while InfluxDB is down
  (`battery_level` 40 % first archived at 15:17:14Z, grid-in first archived
  14:31:42Z); `select.apex300_working_mode` is not in the archive at all. The
  lar's previous-container log **survived** this time (`kubectl logs
  --previous`) — luck, not design.
- **Nothing paged.** No rule covers `jupiter_lar_battery_telemetry_stale` or
  `jupiter_lar_ha_read_ok`; `JupiterLarSocUnknown` never armed because the
  last-good held. The only alert the cut produced was `KubeJobFailed` for the
  `influxdb-buckets-29856380` cron run (pending 14:22Z, firing 14:37Z).
- **Safety exposure:** none. Every unusable reading degraded to a hold or a
  last-good value; the one write on a frozen SoC commanded a discharge on a
  battery that was really at 40 %. The availability exposure is physical: the
  rack and vesta are on the battery's AC output (#331).

## Timeline (2026-10-07, UTC)

| Time | Event |
|---|---|
| 10-06 16:48 / 17:01 | lar **0.22.0** pins + `battery_freshness_mode: enforce` merged (gitops #458, master `df80199` 16:58Z); the lar container restarts 17:01:10Z on 0.22.0 with `mode=enforce`. Normal night and morning: 22 plan/recheck/spike writes 17:02Z → 12:57Z, pushes every 5–10 min (`bluetti_report_ages` push age resets at 12:01, 12:13, 12:23, 12:30, 12:40, 12:45, 12:53). |
| 12:44:53 | Last archived SoC change: **46 %** (grid-in 483 W, AC-out 484 W). |
| 12:54:46 | **Last real push** (AC-out 468 W, grid-in 469 W). The push age last resets at the 12:53:06 scrape and climbs to 675 s by 13:04:06, where the gauge freezes (the helper sensor itself stopped). |
| 12:56:52 | Spike TRIGGER: 2 fresh readings ≥ 2.0 kW (observed 2.59 kW; HEM import 3.07 kW at 12:57), SoC 46 % ≥ 20 % → `applied live: DISCHARGING 2.59 kW (spike override)`; `mode_writes_total{discharging,spike}` 3 → 4. |
| 13:00:11 | Plan charge 1.311 kW — overridden by the active spike (no write). `jupiter_lar_ha_read_ok` reads 0 from the 13:00:36 scrape. |
| 13:05:05 | **First placeholder-only reload** (51 % / 2008 W / 607 W archived; never replaced by real values). From here the lar's 10 s poll reads the Bluetti entities as unusable (`unavailable`/`unknown`): "spike battery grid-input unusable (no sample)" ×424 until the cut; `actual_mode_known` 0 from 13:05:06. The module is off the LAN. |
| 13:15:10 | `SoC read failed; holding last-good 46.0%` (×5: 13:15, 13:30, 13:45, 14:00, 14:15). `ha_read_errors_total{read="soc"}` and `{read="house_load"}` 0 → 4 by 14:00:36. Telemetry age at the cycle: 604 s (< 900). Plan charge 1.311 kW, overridden. |
| 13:20:35 | Self-heal reload → placeholder; the lar rejects it for `spike_sample` + `measured_mode` (counters 44 → 45). Entity timestamps re-stamped. |
| 13:30:10 | Cycle: age 574 s (< 900, measured from the 13:20:35 reload). Plan idle. |
| 13:40:35 | Reload → placeholder (rejected, 45 → 46); timestamps re-stamped. |
| 13:45:10 | Cycle: age 274 s. Plan idle. |
| 14:00:10 | **STALE:** "freshest of 3 battery reads is 1174s old (> 900s)" → 14:00:13 `applied live: PASSTHROUGH (stale telemetry -> passthrough (hold))`; plan charge 0.260 kW suppressed; `mode_writes_total{passthrough,safety}` 0 → 1; `jupiter_lar_battery_telemetry_stale` 1 from the 14:00:36 scrape. The cycle ran 25 s **before** the next reload. |
| 14:00:35 | Reload → placeholder (rejected, 46 → 47); timestamps re-stamped again. |
| 14:0x → 14:17 | Owner at the front panel attempting the #319 route (hold AC power + ECO ~2 s → P07); settings mode never appeared. LAN sweeps from the Windows host (14:08, 14:30): router `.1`, mesh nodes `.2`/`.103`, ~40 hosts and the pomona ESP32 answer; the Bluetti MAC is absent → unit-side, not the AP (same conclusion as 10-05). |
| 14:08 → 14:15 | House import drops to 350–540 W (HEM), i.e. the real spike is long over — the override cannot see it. |
| 14:15:10 | `SoC read failed; holding last-good 46.0%`. Age now ≈875 s since the 14:00:35 reload (< 900) → **stale flag clears**. |
| 14:15:11 | Plan idle → `applied live: DISCHARGING (discharge=2.59kW, spike override)` — the latched override re-applied on the frozen 46 %. Last line of the lar's log. |
| ~14:15:12 | **AC output off** — a single press of the AC power button while trying to reach settings mode. Last node-exporter scrapes 14:14:49–14:15:18Z per node; HA's last archive write 14:14:47Z; kubelet-stamped container terminations 14:15:12Z (and 14:18:05–07Z for pods on nodes whose kubelet came back later). |
| 14:16:23 → 14:16:33 | All six nodes boot (`node_boot_time_seconds`; possibly pre-NTP). The AC output was off for roughly a minute. |
| 14:18:29 → 14:21:10 | 166 containers start (4 at 14:15Z — clock-skew artefact —, 137 at 14:18, 11 at 14:19, 12 at 14:20, 2 at 14:21). jupiter-cell restarts 14:18:29Z (exit 255, restart 1). reporting-service 14:18:38Z; price-service 14:20:07Z; forecast-service 14:21:10Z; jupiter-pg-2 14:19:37Z, jupiter-pg-1 14:21:00Z. |
| 14:18:32 | lar cold start: placeholder guard ARMED, freshness `mode=enforce`; price/forecast services refused (not up yet) → **last-good caches** (192 price points, 36 forecast points). |
| 14:18:33 | **Real SoC 40 % read** (vesta was back before the lar) → plan `charge=0.758kW` → `applied live: CHARGING`. The 0.21.0 cold-start hold was not needed. The module is back on the cloud — within ~3 min of the AC toggle; what restored it (the toggle, a settings-mode entry that went unnoticed, a unit restart) is **not established**. |
| 14:19:14 | Spike TRIGGER 2.24 kW (SoC 40 %) → DISCHARGING. |
| 14:21:02 → 14:21:31 | Prometheus scraping again (`count(up)` 17 at 14:20:15 → 80 at 14:21:30); first lar scrape 14:21:24Z: `soc_pct` 40, `telemetry_age_seconds` 9.7, `stale` 0, `soc_unknown` 0; HA archive writes resume 14:21:31Z. |
| 14:21:04 / 14:21:14 | Push-aware verdict "REST says STALE but the feed is ALIVE — enforce, acted on" (#320); spike RELEASE → `CHARGING 0.76 kW`. |
| 14:25:35 / 14:27:35 | Spike TRIGGER 2.33 kW → DISCHARGING; RELEASE → CHARGING. HEM import 2.26–2.33 kW 14:26–14:31Z. |
| 14:30:06 | Charge guard TRIP (quarter mean 2.30 kW ≥ 2.5 − 0.2) → `PASSTHROUGH (guard hold)` until 14:45. Plans 14:30, 14:45, 15:00: idle. |
| 14:31:42 | First archived real grid-in reading after the restart (583 W). |
| 14:37 | `KubeJobFailed` fires for `influxdb-buckets-29856380` (the 14:20Z cron run hit the InfluxDB restart). |
| 15:15:11 | Plan `discharge=0.291kW` → `applied live: DISCHARGING`. 15:30: 0.44 kW. SoC 40 → 39 (15:22Z) → 38 (15:42Z). Push-aware ALIVE/feed_quiet pairs every ~7 min from 15:20Z: the feed is pushing again. |
| 18:43 | This review's own check: the Windows ARP table (38 LAN entries) has no entry for `.81` / `00-4b-12-…` although the cloud path works (open question, weak evidence: ARP only lists hosts that exchanged frames with this PC). |

## Causal chain (5-whys)

1. **Why was the battery without telemetry for 84 minutes?** The unit's
   WiFi/IoT module left the LAN between 12:54:46 and 13:05:05Z; the cloud had
   nothing fresh; HA's entities went `unavailable` after each reload's failed
   fetch, with only the placeholder triple at the reload instant.
2. **Why did the module drop?** **Not established** — second time in 48 h,
   same signature as 10-05 minus the write flap (one select write at 12:56:52Z
   in the preceding half hour). The 10-05 full-unit restart did not cure it.
3. **Why did the rack and vesta lose power?** The owner went to the front
   panel to run the WiFi-only route recorded on #319 two days earlier (hold AC
   power + ECO ~2 s → P07). Settings mode never appeared, and on this panel a
   single press of AC power toggles the AC output — the output the rack and
   vesta are wired to (#331). The route had been copied from the manual, never
   rehearsed, and carried no warning about the single-press behaviour.
4. **Why was the owner at the front panel at all?** The only recovery paths
   for a dead module are a WiFi reset or a unit restart: there is no local
   telemetry/command path (#217/#309), and the self-heal's escalation
   notification tells the owner to "power-cycle the battery" (home-assitant
   `bluetti-selfheal.md` §2b) — the one action that is also an outage.
5. **Why did the lar command DISCHARGING on a frozen SoC at 14:15:11Z?** Two
   mechanisms interact: (a) the spike override latched at 12:56:52Z on a real
   spike and has no release path without samples — release needs three fresh
   readings ≤ 1 kW, and with the #178 correction configured a dead Bluetti
   feed means *no sample at all*, so the override can neither release nor see
   that the house load fell to 350 W; (b) the #211 stale guard measures the
   freshest entity timestamp, which every self-heal reload re-stamps
   (placeholder → unavailable transitions), so with reloads at 13:05, 13:20,
   13:40 and 14:00 the age exceeded 900 s in only one cycle (14:00:10, which
   happened to run 25 s before the 14:00:35 reload). The controller's own
   invariant ("the spike override must never add discharge on a frozen SoC")
   held whenever the flag was armed; the flag's input was defeated by the
   self-heal's cadence.

**Aggravating factors:** nothing paged during 84 min of dead telemetry
(jupiter alerts route to null, #250; no stale-telemetry rule exists at all);
HA's InfluxDB export drops writes while InfluxDB is down, so the archive has a
hole exactly where the recovery happened; the cold start ran while the central
services were still down (the last-good caches carried it — as designed); the
two post-restart spike responses on the battery's own charge ramp cost a guard
hold through 14:45Z.

## Resolution — what was deployed

1. **Physical (fix of the moment):** the AC output was switched back on; the
   rack, vesta, the cluster and the lar recovered on their own within ~6 min.
   The module was back on the cloud by 14:18:33Z — the mechanism is not
   established, so this is not a fix.
2. **Procedure (this PR, docs only):** the 10-05 review's item 2 and its open
   runbook checkbox now carry the front-panel warning — **never press AC
   power alone**, wake the LCD with ECO, settings mode is signalled by the
   frequency icon flashing (no separate screen), check child lock P08 if the
   combo does nothing, and prefer the app's Bluetooth → "Reset WiFi" path.
   See the amended `2026-10-05-bluetti-wifi-drop-and-rack-power-cycle.md`.
3. **Nothing in the lar, HA or the cluster was changed today.** 0.22.0's new
   parts behaved: the push-aware freshness in enforce (#320) accepted the live
   feed after the restart (ALIVE verdicts 14:21:04Z onward) and never held the
   controller on a constant value; the placeholder guard discarded every reload
   snapshot (3 + 3 rejections); the LP planned no wash (`simultaneous_flows`
   0, #324).

Reverted: nothing.

## What held / what did not

**Held:** the placeholder guard (3 reload snapshots discarded per consumer,
SoC never replaced by 51); the last-good SoC (46 %) through 5 failed reads;
the stale hold when it was armed (14:00:13Z, the plan's charge suppressed);
the cold start on a real SoC with cached price/forecast curves while the
central services were down; push-aware freshness in enforce (#320) after the
restart; the charge guard (14:30:06Z); the churn guard's write budget (6 writes
in 12 min, none suppressed); the cluster came back by itself with no stuck pod
and healthy Longhorn/CNPG; the lar's previous-container log survived for this
review.

**Did not:** the stale guard was armed for one of five cycles because the
self-heal's reloads re-stamp the timestamps it measures; the spike override
latched for 78 min with no release path and was re-applied on a frozen SoC;
the #178 correction had no subtrahend after the restart and the battery's own
charge ramp fired the responder twice; nobody was paged; the recovery route
documented two days earlier took the rack down on first use; the self-heal's
own escalation text points the owner at a power cycle; HA's archive dropped
the recovery's writes.

## What went well / what went poorly (blameless)

**Well:** the owner recognised the 10-05 signature at once and diagnosed
"unit-side, not the AP" with the same LAN sweep before touching anything on
the cluster; the AC toggle was a one-minute outage and everything downstream
self-recovered; the lar came up on cached inputs and a real SoC; the archive
and the surviving pod log let this review reconstruct the gap to the second.

**Poorly — lessons:**
- **L1 (10-05 L1, now proven twice):** anything plugged into the Apex 300's
  AC output is one button-press from a reboot. *Until #331 moves the rack and
  vesta to a bypass/UPS, the front panel is off-limits during an incident; the
  phone app over Bluetooth is the only hands-on path.*
- **L2:** a procedure transcribed from a manual is not a runbook until it has
  been rehearsed. *Rehearse hands-on recovery steps on a calm day with the rack
  on bypass, and write down what each button does when pressed alone.*
- **L3:** a staleness guard keyed on timestamps is only as good as what stamps
  them. The self-heal's reloads (every 15–20 min in this episode) kept the
  Bluetti entities "younger" than the 900 s threshold while they carried no
  data. *A placeholder or an unavailable state must count as "no heartbeat"
  for the stale verdict, or the self-heal must back off to beyond the
  threshold once the placeholder never clears (hephaestus / hestia).*
- **L4:** a held override with no release path is a latch. *The spike
  override needs a bounded hold — "no sample for N seconds → release to the
  plan (or to the hold)" — the same rule the 10-05 review applied to unknown
  SoC (ADR-0029 D).*
- **L5:** the escalation message is part of the control path. *"Power-cycle
  the battery" must become "reset WiFi from the app; never the front-panel AC
  button" (hestia, bluetti_selfheal).*
- **L6:** "nothing fired" twice in 48 h for a dead feed. *Alert on
  `jupiter_lar_battery_telemetry_stale == 1` and `jupiter_lar_ha_read_ok == 0`
  with a `for` matched to the reload cadence (atlas / cerberus).*

## Action items

- [x] AC output restored; telemetry, cluster, HA recovered (~14:21Z); LAN sweep + ARP check recorded here
- [x] 10-05 review and the P07 procedure amended with the front-panel warning (this PR)
- [ ] **#331 power topology (headline):** move the rack + vesta off the Apex 300's AC output (bypass/UPS) — owner decision; this is the structural fix for both 10-05 and 10-07
- [ ] #319: rehearse the WiFi-only route once with the rack on bypass; document the app's Bluetooth → "Reset WiFi" path as the first choice and child lock P08 as the first check; add the warning to `home-assitant/bluetti-selfheal.md` and the jupiter ops notes (hestia / owner)
- [ ] hestia: bluetti_selfheal escalation text (§2b "power-cycle the battery") → the safe procedure; bump the package version
- [ ] hephaestus (new card): (a) stale verdict must ignore placeholder/unavailable re-stamps or key off the push-aware liveness instead of REST timestamps; (b) spike override: bounded hold / release on N s without samples; (c) confirm which subtrahend the #178 correction used for the 14:19:14 and 14:25:35Z triggers; replay 12:30 → 14:30Z from the recorded inputs
- [ ] atlas / cerberus: PrometheusRule on `jupiter_lar_battery_telemetry_stale` and `jupiter_lar_ha_read_ok` (#250 routing is still null — both would have mattered today and on 10-05)
- [ ] hestia: HA InfluxDB export drops writes while InfluxDB is down (recovery minutes missing from the archive) — retry/queue setting
- [ ] atlas: clear the failed `influxdb-buckets-29856380` job so `KubeJobFailed` resolves; post-power-cut integrity check of the stateful workloads (Longhorn/CNPG/InfluxDB report healthy; "healthy" is not "nothing lost")
- [ ] #217 / #309: a local telemetry + control path — second incident in 48 h with the same root
- [ ] Open question: the module's MAC is still absent from the Windows ARP table after recovery while the cloud path works — does the module now sit on a different AP/VLAN path, or only talk outbound? (owner, next LAN sweep)
- [ ] 10-05 open items unchanged: #228 part 4 re-judge, #324 done in 0.22.0 (verify), #323, savings-counter handling of placeholder inputs, push-detector under-count

## Unverified

- The cause of the module drop (both occurrences).
- What restored the module at ~14:18Z (the AC toggle, an unnoticed settings-mode entry, or a unit restart) — owner to confirm.
- Whether the 12:56:52Z DISCHARGING and the 14:15:11Z re-apply reached the unit; the unit's actual mode 12:57 → 14:15Z (`select.apex300_working_mode` is not archived; the −6 SoC points are consistent with discharge, the 2.0–2.3 kW house import is not consistent with a 2.59 kW discharge).
- The exact instant of the cut: between the lar's last line 14:15:11.48Z and the first kubelet termination stamp 14:15:12Z; node boot times 14:16:23–33Z may be pre-NTP; four "containers started 14:15:26Z" are clock skew.
- The #178 subtrahend during the two post-restart triggers (archive hole 14:00:35 → 14:31:42Z for grid-in).
- Whether cerberus or the self-heal's 30-min escalation push reached anyone (Trello and Grafana MCPs were down for this review).

## Evidence (reproducible)

- Prometheus (`svc/kube-prometheus-stack-prometheus`, queried via `wget` in
  `prometheus-kube-prometheus-stack-prometheus-0`; raw samples from instant
  queries with range selectors unless noted):
  `jupiter_lar_soc_pct[4h]`, `jupiter_lar_battery_telemetry_stale[4h]`,
  `jupiter_lar_battery_telemetry_age_seconds[4h]`,
  `jupiter_lar_ha_read_ok[4h]`, `jupiter_lar_actual_mode_known[4h]`,
  `jupiter_lar_spike_state[4h]`, `jupiter_lar_target_charge_kw[4h]`,
  `jupiter_lar_battery_report_ages_push_seconds[4h]`,
  `jupiter_lar_battery_placeholder_rejected_total[4h]`,
  `jupiter_lar_ha_read_errors_total[4h]`, `jupiter_lar_mode_writes_total[4h]`,
  `jupiter_lar_spike_responses_total[4h]`, `jupiter_savings_today_eur[4h]`,
  `jupiter_savings_discharged_today_kwh[4h]` — all at `time=2026-10-07T16:00:00Z`;
  `up{job="node-exporter"}[40m]` and `up{job="jupiter-cell"}[40m]` at 14:40Z;
  `count(up)` range 14:10 → 14:40Z step 15; `node_boot_time_seconds` instant;
  `count(kube_pod_container_state_started >= S and < S+60)` per minute
  14:15 → 14:22Z; `sum(kube_pod_container_status_restarts_total)` at 14:00Z and
  14:40Z; `ALERTS{alertstate="firing"}` range 12:00 → 16:00Z step 60 and
  `ALERTS{alertstate="pending"}[4h]`; `/api/v1/rules?type=alert` filtered on
  `telemetry_stale|placeholder|freshness|read_errors|soc_unknown|ha_read_ok`.
- lar logs: `kubectl -n jupiter-tervuren logs jupiter-cell-6b749d889d-7tp9g
  --previous` (10-06 17:01:11 → 10-07 14:15:11Z) and the current container
  (14:18:31Z →).
- kubectl: `get nodes` (Ready `lastTransitionTime`), `get pods -A -o json`
  (`lastState.terminated.finishedAt`, `state.running.startedAt`),
  `get volumes.longhorn.io -n longhorn-system`, `get clusters.postgresql.cnpg.io -A`,
  `get jobs -n influxdb`.
- HA archive, InfluxDB bucket `homeassistant` (read-only `influx query` in
  `influxdb-influxdb2-0`, org `zeus`): entities
  `office_buzzbrick_battery_level`,
  `office_buzzbrick_ap3002532000565690_grid_input_power`,
  `…_alternating_current_out_power` (field `value`) 12:30 → 15:00Z and
  `battery_level` 14:00 → 19:00Z;
  `utility_room_home_energy_meter_electric_consumption_w` 1-min max 12:50 →
  13:10Z, 5-min max 13:10 → 14:15Z, 1-min max 14:05 → 14:40Z, and its sample gap
  14:14:47 → 14:21:31Z; `office_buzzbrick_*` first samples after 14:15Z.
- Code (jupiter `jupiter-rel-0220`, v0.21.0-16-g90d43f4): `services/lar/jupiter_lar/controller.py`
  (stale branch before the spike override; the "must never add discharge on a
  frozen SoC" invariant), `ha_state.py` (`battery_telemetry_stale` = min
  liveness age over the Bluetti reads > `battery_stale_after_seconds` 900;
  "SoC read failed" = non-numeric state, distinct from the placeholder path;
  spike sample `None` on `unavailable`/`unknown` grid-in), `spike.py` (release
  only on `release_consecutive` fresh readings ≤ `release_kw`; no max hold).
- home-assitant `packages/bluetti_selfheal.yaml` 1.2.0 and
  `bluetti-selfheal.md` §2b (the "power-cycle the battery" notification).
- Windows host: `arp -a` at 18:43Z (38 LAN entries, none for `.81` /
  `00-4b-12-…`); owner's LAN sweeps 14:08 / 14:30Z (card #319 comments).
- Manual: Bluetti Apex 300 user manual (manualslib.com/manual/3980279, p. 17:
  hold AC power + ECO ~2 s, frequency icon flashes, ECO navigates, AC power
  adjusts, hold both to exit, 1 min idle exits without saving; p. 12: "press any
  button to activate the LCD"; child lock P08 disables all buttons).

## References

gitops: this review; #456 (10-05 review); #458 (0.22.0 pins + freshness
enforce); #448 (mode-write alert rules) · jupiter: ADR-0028 (placeholder
guard, push-aware freshness), ADR-0029 (mode-write discipline), ADR-0032 (LP
net-discharge incentive) · cards #331 #319 #320 #228 #217 #309 #250 #177 #178
#211 #213 · related: `2026-10-05-bluetti-wifi-drop-and-rack-power-cycle.md`,
`2026-09-12-bluetti-all-zero-freeze-and-reload-only-values.md`,
`2026-08-31-bluetti-staleness-deadlock.md` · home-assitant
`bluetti-selfheal.md`
