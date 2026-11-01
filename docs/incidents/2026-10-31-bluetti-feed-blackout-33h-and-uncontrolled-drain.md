# Post-incident review — Bluetti feed blackout (33 h), the uncontrolled drain 70 % → 18 %, and the rack power cycle at the battery's floor (cards #331, #333, #342, #217/#309)

**Date:** 2026-10-31 → 2026-11-01 · **Severity:** high (33 h without battery
telemetry; the battery drained 70 % → 18 % under a command the controller had
long withdrawn; an unplanned outage of the whole k3s cluster plus vesta,
~5 min; 8 h 40 min of a controller with no SoC at all; no safety exposure;
cost small) · **Status:** mitigated — the feed returned by itself at 17:39:36Z
on 11-01, the lar read a real SoC and resumed; the feed dropped **again** at
~18:08Z and was back after the 18:20Z reload; the cause of the module drops is
still not established, nothing in the lar/HA/cluster was changed, and the
rack-on-the-battery coupling (#331) is unchanged · **Format:** blameless
SRE-style postmortem with an A3-style summary box. All times **UTC**
(local = UTC+1 since 10-25).

This is the sixth loss of the Bluetti feed in four weeks (10-05, 10-07, 10-08
afternoon, 10-14 15:15–16:45Z, **10-30 15:15–22:20Z (7 h, unreviewed — found in
the archive while writing this)**, 10-31 → 11-01). It is the longest, and the
first in which the battery itself paid for it.

---

## A3 summary (one-box view)

| | |
|---|---|
| **Background** | The Apex 300's WiFi/IoT module is the only path to the Bluetti cloud, and the cloud is the only path HA and the lar have for telemetry *and* commands (#217/#309). The homelab rack (6 nodes) and vesta (HA) hang off the Apex 300's AC output (#331). The lar (0.22.0, push-aware freshness in enforce) commands the unit through an HA select; `Custom` = DISCHARGING, `Time of Use` = PASSTHROUGH, `Backup` = CHARGING. When the feed dies the lar *holds* PASSTHROUGH: it suppresses its own plan writes and keeps its last-good SoC in memory. HA's self-heal reloads the integration every 15 min; every reload publishes the placeholder triple 51 % / 2008 W / 607 W / `Backup` with a fresh timestamp. |
| **Problem** | At 08:00:12Z on 10-31 the lar commanded DISCHARGING 0.25 kW (serve the rack from the battery). The last real push came at 08:23:35Z; from 08:40:05Z HA showed only the placeholder for 33 h. The hold never *reached* the unit, so the battery kept serving the rack (~270 W) from 70 % down to its own floor (~18 %). When it got there, ~09:02Z on 11-01, the AC output dropped: all six nodes and vesta rebooted. The lar came back with no SoC at all (the last-good lives only in memory) and sat in a SoC-UNKNOWN hold for 8 h 40 min, planning from an assumed 10 % at 37–41 EUR per plan. The feed returned at 17:39:36Z with the battery at 18 %; the lar charged it back at the evening peak price into the capacity guard. Nothing paged: one HA "values only arrive at a reload" notification at 08:53Z on 10-31, and `JupiterLarSocUnknown` firing for 8 h into the `null` receiver. |
| **Direct cause** | Telemetry: the module stopped pushing between 08:23:35Z and 08:40:05Z on 10-31 (cause unknown, same signature as the five earlier drops). Drain: the lar's hold is a *controller* invariant — it stops the lar writing, it does not put the unit into PASSTHROUGH — and the one PASSTHROUGH write it did make (~08:30:10Z) was never confirmed by the unit (it still reported `Custom` 33 h later). Outage: the rack is on the AC output, and the unit interrupted it when it reached its discharge floor (most consistent explanation; see Unverified). SoC-UNKNOWN for 8 h 40 min: the last-good SoC is in-memory only; price/forecast curves survive a restart on the emptyDir, the SoC does not. |
| **Root cause** | One cloud-only path for telemetry and command with no local fallback (#217/#309); the rack and vesta downstream of the device being controlled (#331); a hold semantics that protects the controller's invariants but leaves the unit in whatever mode it last accepted; a last-good SoC that does not survive the process; a self-heal whose 15-min reloads re-stamp every timestamp the staleness detectors (lar REST age 900 s, HA `bluetti_telemetry_stale`) key on, so neither the lar's stale hold nor the HA self-heal *episode* ever armed; and alert routing that sends every jupiter alert to `null` (#250). |
| **Countermeasures** | Nothing shipped. The feed recovered on its own at 17:39:36Z; the lar re-planned from a real SoC and charged 17:45–18:15Z until the charge guard tripped. #333 (atlas, in progress on `card-333`) is building the dead-feed alert rules; the evidence table in this review is for that card. Proposed: a placeholder/push-aware stale signal (the HA `binary_sensor.bluetti_push_dead` was correct for the entire 33 h), a bounded hold that *writes* PASSTHROUGH to the unit on a dead feed, a persisted last-good SoC, #331, #217/#309. |
| **Verification** | 17:39:36Z real SoC 18 % in HA; lar `applied live: CHARGING 1.61 kW` 17:45:11Z, select `Backup` 17:45:44Z, grid-in 1996 W from 17:46:16Z, SoC 18 → 23 % by 18:20Z; guard trip 18:15:04Z → PASSTHROUGH, house import 4.6 → 0.9 kW by 18:24Z. Cluster: 6/6 nodes Ready (Ready-since unchanged), 181 containers started 09:03 → 09:09Z, Longhorn 18/18 attached volumes healthy (2 detached = unused), CNPG `ceres-pg`/`jupiter-pg`/`harbor-pg` healthy. At this review's last look (18:34:26Z) the lar reads SoC 24 %, telemetry age 0.1 s, mode PASSTHROUGH known. |
| **Follow-up** | #333 (alert on a placeholder-aware signal, not on `telemetry_stale`); hephaestus: hold must write PASSTHROUGH / bounded hold / persist last-good SoC / cold-start without SoC should not plan a full recharge at 37 EUR; hestia: the self-heal episode never starts while the force-refresh reload keeps re-stamping, and the one notification it sent did not say the battery was draining; #331 (owner); #250 routing; #342 Fluvius peak read; #217/#309; the 10-30 7-h blackout and the 11-01 18:08Z re-drop need the same cause work as the five before. |

---

## Impact

- **Telemetry blackout 08:23:35Z 10-31 → 17:39:36Z 11-01 (33 h 16 min from the
  last push; 32 h 59 min from the first placeholder at 08:40:05Z).** The
  brief's "29 h from 12:25Z" undercounts: HA's `battery_level` archive shows
  the last real value (70 %) at 08:10:46Z and the placeholder 51 from
  08:40:05Z; 12:25Z is one of the ~133 reload instants. In the whole window
  HA archived no real Bluetti value; the lar read the placeholder every 10 s
  (`placeholder_rejected_total{consumer="soc"}` +1 per 15-min cycle,
  `{consumer="spike_sample"}` +~364/h).
- **Uncontrolled drain 70 % → 18 % (52 SoC points ≈ 6.8 kWh of the 13.0 kWh
  usable).** The unit stayed in `Custom` (the lar's DISCHARGING 0.247 kW of
  08:00:12Z) and served the AC-output load — the rack, 250–320 W (15-min means
  of `alternating_current_out_power` 10-30 22:30 → 10-31 08:30Z) with grid-in
  0 W — for ~25 h: 0.27 kW × 25 h = 6.75 kWh, which is the 52 points to the
  decimal. The lar meanwhile *planned* 0.25–0.79 kW discharges on 10-31
  evening and charges on 11-01 and wrote none of them. The house import
  (HEM) sat at 185–215 W at 08:20–08:43Z on 10-31 with the rack on the
  battery, and at 450–650 W from 09:09Z on 11-01 with the rack on the grid.
- **Energy cost (estimate, small):** gross, 6.8 kWh bought back at the evening
  import price 0.31–0.32 EUR/kWh ≈ **€2.1**; net of what the rack would have
  cost from the grid in PASSTHROUGH over the same hours (0.20–0.27 EUR/kWh,
  ≈ €1.6) plus round-trip losses (~0.7 kWh) and the suppressed 10-31 evening
  discharge (≈ 3 kWh of plan intent over a ~0.05–0.08 spread), ≈ **€0.5–1.0**.
  The savings counter cannot price it: `jupiter_savings_today_eur` closed
  10-31 at €0.016 (10-30: €0.121), ran negative overnight (−0.009 at 09:00Z),
  reset to +0.14 when reporting-service restarted, and read €0.03 at 18:00Z —
  its SoC input was the frozen 70 then the assumed 10 (`jupiter_reporting_soc_percent`).
- **Cluster + HA outage ~09:02 → ~09:09Z on 11-01 (~5–7 min).** The lar's
  previous container logged its last line at 09:01:52Z; `node_boot_time_seconds`
  09:03:45–09:03:51Z for **all six nodes** (not node03 alone — every node's
  containers show `exit 255, reason Unknown`); Prometheus scrape gap
  ~09:02 → 09:07:30Z (`count(up)` 85 → 22 → 85); HA's InfluxDB export has a
  hole 09:04 → 09:08Z (the HEM sensor too); 181 containers started after
  09:01:40Z; `sum(kube_pod_container_status_restarts_total)` 355 → 515. No pod
  stuck; `jaeger` OOM-killed once at 09:08Z while everything came up; Harbor
  core/jobservice/exporter and the ceres apps exited 1–2 on dependency order
  and recovered. Node `Ready` transitions did not move (the API server was
  down with the rest, so nothing recorded NotReady).
- **Controller without a SoC 09:05:33 → 17:45:11Z (8 h 40 min):** "SoC read
  failed and no last-good; using safe default soc_min 10.0 %" at cold start,
  then "SoC read is a reload placeholder and no last-good" ×34 and "battery
  SoC UNKNOWN — holding PASSTHROUGH" ×35. Plans from an assumed 10 %:
  charge 1.62–1.80 kW, `jupiter_lar_plan_cost_eur` **37.3–41.2** (10-31:
  1.26–1.95). None actuated. `JupiterLarSocUnknown` pending 09:05Z, firing
  ~09:25 → 17:45Z — into the `null` receiver.
- **Four PASSTHROUGH writes 15:10:47–15:20:25Z** (`mode_writes_total{passthrough,safety}`
  2 → 6): HA core restarted three times (15:10:43, 15:17:02, 15:20:23Z — every
  automation's `last_triggered` re-written), the lar's select calls failed
  (connection refused ×11, HTTP 400 ×3), it stood down ("control hold:
  control_call_failed") and re-applied the hold each time HA came back.
  Correct behaviour; the restarts themselves are unexplained (owner?).
- **Recharge at the evening peak into the capacity guard:** 17:45:11Z
  CHARGING 1.61 kW on 18–19 %; grid-in 1.77–2.01 kW; house import 2.3–2.4 kW
  (17:47–17:56Z), 3.2–3.4 kW (18:09–18:18Z) and **4.6–4.7 kW** (18:19–18:21Z,
  1-min maxima) with cooking on top; the charge guard tripped at 18:15:04Z
  (quarter mean 2.25 kW, projected 3.34 ≥ 3.00 − 0.20) and the PASSTHROUGH
  landed at ~18:22Z (import 4.6 → 2.4 → 0.88 kW by 18:24Z). November 1 is a
  new billing month: the Fluvius peak read is failing (#342, "capacity-peak
  read failed; holding in-month last-good 3.00 kW" 10:15–11:00Z), so the guard
  worked from the 3.00 kW target. From the 1-min maxima the 18:00–18:15 and
  18:15–18:30 quarters average ≈ 2.5 kW — probably November's peak on day one,
  below the target, but set by charging during dinner. Four earlier trips
  (16:04, 17:15, 17:34Z) had nothing to override.
- **The feed dropped again at ~18:08Z** (last changing value 18:07:59Z); the
  self-heal's episode automation fired for the first time in the whole
  incident at 18:20:00Z, the reload archived the placeholder again, and at
  18:34:26Z the lar read SoC 24 % with telemetry age 0.1 s — alive again.
- **Nothing paged.** For the 33 h: one HA push notification at 08:53:00Z on
  10-31 (`automation.bluetti_push_dead_tell_the_owner_the_values_only_arrive_at_a_reload`),
  no self-heal episode, no 30-min/2-h escalation, no Prometheus alert
  (`jupiter_lar_battery_telemetry_stale` = 0 throughout; no rule on
  `ha_read_ok`, `placeholder_rejected`, `actual_mode_known` or the push age).
  For the 8 h 40 min after the restart: `JupiterLarSocUnknown` fired and was
  routed to `null` — the Alertmanager route only forwards `namespace="zeus"`
  to the HA webhook (#250).
- **Evidence loss:** the lar's previous-container log is rotated and starts
  at 17:46:31Z on 10-31 — the morning of the drop (the 08:30Z write, the last
  real SoC read, the first placeholder rejections) survives only in
  Prometheus and the HA archive. HA's export dropped 09:04 → 09:08Z while
  InfluxDB was down (as on 10-07).
- **Safety exposure:** none from the controller (every unusable reading
  degraded to a hold; the one plan write after recovery was on a real SoC).
  The availability exposure is physical and now demonstrated end-to-end: a
  dead feed → an unwithdrawn discharge → the battery's floor → the rack and HA
  lose power (#331).

## Timeline (UTC)

| Time | Event |
|---|---|
| 10-30 15:15:06 | Previous blackout (context): placeholder archived; self-heal episode started 15:15:00; escalation "power-cycle" notification 22:00:45; real values back 22:20:46 (77 %). 7 h 5 min, not reviewed. |
| 10-31 05:45:11 / 07:45:12 / 08:00:12 | Plan writes DISCHARGING (`Custom`) / PASSTHROUGH (`Time of Use`) / **DISCHARGING (`Custom`), target 0.247 kW** — the last command the unit confirmed. Grid-in 0 W, AC-out ~270 W: the rack on the battery. |
| 08:10:46 | **Last real SoC: 70 %** (`battery_level` 71 → 70). Lar `soc_pct` 70 from the 08:16 scrape, frozen there until 09:01:52Z next day. |
| 08:23:35 | **Last real push** (`bluetti_report_ages` push_s resets to 25 at 08:24:00 and climbs from there; the lar's `battery_report_ages_push_seconds` likewise). |
| ~08:30:10 | Plan PASSTHROUGH write (`mode_writes_total{passthrough,plan}` 171 → 172 between the 08:30 and 08:45 scrapes). No select transition archived; the unit reported `Custom` when the feed returned — the write did not take. `telemetry_age` 211 s at 08:35. |
| 08:40:05 | **First self-heal force-refresh reload → placeholder** (51 / 2008 / 607 / `Backup`) archived; `bluetti_telemetry_stale` on for 380 ms then off; `bluetti_integration_alive` off → on. Lar: `placeholder_rejected{soc}` 239 → 240, `actual_mode_known` 0 from 08:45, push-age gauge frozen at 985 s. From here one reload every 15 min (:10/:25/:40/:55) for 33 h; each re-stamps every Bluetti entity. |
| 08:53:00 | `binary_sensor.bluetti_push_dead` → **on**; the push-dead notification fires — the only message of the incident. It stays on until 17:41:47Z the next day. |
| 10-31 10:00 → 11:45 | `JupiterLarCapacityPeakReadsFailing` firing (then clears; #342). |
| 10-31 daytime → 11-01 09:01 | Every 15-min cycle: plan (discharge 0.25–0.79 kW on the evening, idle/charge at night, cost 1.26–1.95 EUR) → "battery telemetry is a reload PLACEHOLDER — holding PASSTHROUGH (the SoC this cycle planned from, 70.0 %, is last-good/unverified); plan intent suppressed"; the 10-s poll repeats the hold (5 613 lines in the surviving 15 h). `mode_writes_total` flat. `telemetry_stale` 0, `telemetry_age` 20–610 s, `ha_read_ok` 0, `ha_read_errors{read="ac"}` +4/h. The unit discharges ~270 W into the rack, ~2 SoC points per hour, unseen. House import 0.2–0.3 kW base, 1.0–1.5 kW peaks (18:30, 21:30, 23:15–00:30Z). |
| 11-01 09:01:52 | Last line of the lar's previous container ("holding PASSTHROUGH … plan intent 'passthrough' suppressed"). Interpolated SoC ≈ 18–20 %. |
| ~09:02 | **AC output interrupted; the rack and vesta lose power.** Kubelet stamps 09:03:00Z (master01) and 09:04:57–09:05:04Z (agents); `node_boot_time_seconds` 09:03:45–09:03:51Z ×6; Prometheus gap to ~09:07:30; HA archive hole 09:04 → 09:08. House import afterwards 450–650 W (rack on grid). |
| 09:05:33 | lar cold start (restart 2): rehydrated 96 price + 36 + 36 forecast points from `/var/cache/jupiter-cell` (emptyDir; survived because the container restarted inside the same pod); **no last-good SoC**; placeholder guard armed, freshness `enforce`; price/forecast/MQTT/Jaeger all refused (cluster still booting) → `price curve (cache) covers only 14.00 h`; plan from 10 %: charge 1.738 kW, cost 38.40 EUR; `applied live: PASSTHROUGH (SoC unknown → passthrough (hold))` ×2 (plan + re-check). |
| 09:15 → 17:30 | 34 cycles "SoC read is a reload placeholder and no last-good; using safe default soc_min 10.0 %"; plans charge 1.62–1.80 kW at 37.3–41.2 EUR; `jupiter_lar_soc_unknown` 1; `JupiterLarSocUnknown` firing from ~09:25Z → `null`. Services back from 09:15 (`service:cache-partial` → `service:primary-partial` by 09:30). `capacity-peak read failed; holding in-month last-good 3.00 kW` 10:15–11:00Z. |
| 15:10:05 → 15:20:25 | HA core restarts (15:10:43, 15:17:02, 15:20:23Z); 11 select calls refused, 3 × HTTP 400; "control hold: control_call_failed; standing down"; PASSTHROUGH re-applied 15:10:47, 15:15:03, 15:17:00, 15:20:25Z. |
| 16:04:23 / 17:15:31 / 17:34:10 | Charge guard TRIP (quarter means 1.87 / 2.16 / 1.96 kW, projected 3.06 / 3.52 / 3.35 ≥ 2.80) — already PASSTHROUGH, nothing to override. |
| 17:39:36 | **Feed back:** `battery_level` **18 %**, grid-in 580 W, AC-out 573 W, select **`Custom`** (the 08:00:12Z command, 33 h later). House import 2.7 → 1.15 kW. What restored the module is not established. |
| 17:40:00 | Reload instant (:40): the REST fetch returns select `Time of Use` (= PASSTHROUGH) — either a queued lar PASSTHROUGH delivered by the cloud on reconnect, or an app action (owner to confirm). Lar `actual_mode` 0 from the 17:45 scrape. |
| 17:41:47 | `bluetti_push_dead` → off; the "clear the notification" automation fires. |
| 17:45:11 | Plan on a real SoC: charge 1.608 kW, cost **15.09** EUR → `applied live: CHARGING (charge=1.61 kW)`; select `Backup` 17:45:44; grid-in 1996 W from 17:46:16; `mode_writes_total{charging,plan}` 0 → 1. SoC 19 (17:48) → 20 (17:55) → 21 (18:01) → 22 (18:05) → 23 (18:20). |
| 18:00:11 | Plan: charge 1.701 kW, cost 10.75 EUR. |
| ~18:08 | Pushes stop again (last changing grid-in 1781 W at 18:07:59Z). |
| 18:15:04 | **Charge guard TRIP** (quarter mean 2.25 kW, projected 3.34 ≥ 3.00 − 0.20) → `applied live: PASSTHROUGH (guard hold, reason=poll_trip)` until 18:30; plan 18:15: cost 7.61 EUR. House import 4.59–4.70 kW 18:19–18:21Z (cooking + the still-charging battery), 0.88 kW by 18:24Z — the hold reached the unit at ~18:22Z. |
| 18:20:00 | Self-heal: `bluetti_self_heal_reload_integration_when_telemetry_frozen` and `bluetti_self_heal_episode_started` fire (first episode of the incident); 18:20:05 archive: 23 % then the placeholder (51 / 2008 / 607 / `Backup`). |
| 18:34:26 | This review's last look: lar `soc_pct` 24, `telemetry_age` 0.12 s, `actual_mode` 0 known, `soc_unknown` 0, `telemetry_stale` 0. The feed is alive again. |

## Causal chain (5-whys)

1. **Why did the battery drain from 70 % to its floor?** At 08:00:12Z on 10-31
   the lar put the unit in `Custom` with a 0.247 kW discharge — "serve the
   rack from the battery, cheap hour". That command stayed in force for 33 h
   because nothing the lar did afterwards reached the unit: the ~08:30:10Z
   PASSTHROUGH write was not confirmed (the select never transitioned, the
   unit still said `Custom` on 11-01 17:39Z), and from 08:40:05Z every cycle
   *held* instead of writing. The hold ("holding PASSTHROUGH, plan intent
   suppressed") is a promise the controller makes to itself — never actuate on
   an unverified SoC — not a state it puts the unit in. The unit kept doing
   the last thing it was told.
2. **Why did no write reach the unit for 33 h?** The module stopped pushing
   between 08:23:35Z and 08:40:05Z and the cloud had nothing fresh — the same
   signature as 10-05, 10-07, 10-08, 10-14 and 10-30; the cause of the drops
   is **not established** (sixth occurrence). Commands go through the same
   cloud path as telemetry (#217/#309), so a dead feed is also a dead command
   path, whether or not HA accepts the select write.
3. **Why did the rack and vesta reboot at ~09:02Z on 11-01?** They are on the
   Apex 300's AC output (#331). The most consistent explanation is that the
   battery reached its `Custom`-mode discharge floor (18 % real at 17:39Z
   after 8.5 h of no further drain; 70 − 25 h × ~2.1 pts/h ≈ 18) and
   interrupted the AC output while switching to grid bypass: the house import
   steps up by the rack's load right after (350–400 W before, 450–650 W
   after), every node booted within 6 s of each other, and vesta went dark
   with them. A grid blip is the alternative (the HEM shows none, and a unit
   in `Custom` is supposed to ride one through). The unit's own event log is
   not accessible; see Unverified.
4. **Why did the lar then spend 8 h 40 min with no SoC at all?** Its last-good
   SoC is an in-memory field. The price and forecast curves are persisted to
   the emptyDir cache and were rehydrated at 09:05:33Z; the SoC is not, so the
   70 % — itself 25 h stale and wrong by 50 points — became "unknown". The
   #228 cold-start rule then did what it is designed to do: assume `soc_min`
   10 % for planning, hold PASSTHROUGH until a real SoC arrives. The plans it
   published from 10 % priced a full recharge plus capacity exposure at
   37–41 EUR per 36 h horizon; harmless because unactuated, misleading on
   every dashboard. The 10-05 review's L-item "what should a cold start do
   with no SoC" is answered: hold — and the hold worked. What it cannot do is
   *shorten* the blind window; only a surviving SoC or the feed can.
5. **Why did nothing arm for 33 h — not the lar's stale hold, not the HA
   self-heal episode, not an alert?** Three detectors, one defeat: the
   self-heal's force-refresh reload every 15 min re-stamps every Bluetti
   entity. The lar's REST age never exceeded 610 s (threshold 900), so
   `battery_telemetry_stale` stayed 0 — exactly the 10-07 L3 mechanism, now
   for 33 h instead of 84 min. HA's own `binary_sensor.bluetti_telemetry_stale`
   went on for ~10 ms at each reload and was cleared by that reload's
   placeholder, so the `for: 2 min` on the episode automation never completed
   and no episode (and no 30-min/2-h escalation) ever started. The one signal
   that was right the whole time — `binary_sensor.bluetti_push_dead`, on from
   08:53:00Z to 17:41:47Z, "no value has changed without a reload around it"
   — only sends a single notification and nothing in Prometheus or the lar
   consumes it. And the jupiter alerts that did exist route to `null` (#250),
   so `JupiterLarSocUnknown`'s 8 h of firing went nowhere.

**Aggravating factors:** the push-dead notification at 08:53Z says the values
only arrive at a reload — it does not say the battery is discharging into the
rack and nobody will stop it; the lar's rotated log erased the morning of the
drop; HA's export dropped the minutes around the power cut; HA core restarted
three times at 15:10–15:20Z for reasons not in the archive; the first plan on
a real SoC (17:45Z) was a 1.6 kW charge at the day's highest import price
(0.31–0.32 EUR/kWh) during dinner, and the capacity guard had to cut it 30 min
later; November's billed peak is unknown because the Fluvius read is failing
(#342), so the guard worked from October's 3.00 kW; the feed dropped again 29
min after it returned.

## Resolution — what was deployed

1. **Nothing was changed** in the lar, HA, the cluster or the unit for this
   incident. The feed returned on its own at 17:39:36Z (mechanism unknown —
   the owner is asked below whether the app was touched); the cluster, HA and
   the lar recovered on their own after the power cut (cached curves, cold
   start hold, re-plan on a real SoC).
2. **This review** records the corrected timeline (the blackout started at
   08:23/08:40Z, not 12:25Z; the reboot was rack-wide, not node03), the drain
   mechanism, the detector defeat on both the lar and HA sides, and the
   evidence #333 needs.

Reverted: nothing.

## What held / what did not

**Held:** the placeholder guard (every reload snapshot rejected: ~133 for
`soc`/`house_load`, ~12 000 for `spike_sample`/`measured_mode`; the SoC was
never replaced by 51); the hold invariant (no write on an unverified or
unknown SoC for 33 h + 8 h 40 min); the #228 cold start (safe default for
planning only, PASSTHROUGH held, real SoC picked up at the first push); the
emptyDir last-good caches for price and forecast at 09:05:33Z while the
central services were down; "control hold: control_call_failed; standing
down" during the HA restarts, with the hold re-applied each time; the charge
guard at 18:15:04Z; the churn guard's write budget (no suppression); the
cluster came back by itself, Longhorn and CNPG healthy; the HA archive kept
the whole story except the power-cut minutes.

**Did not:** the hold protected the controller, not the battery — the unit
stayed in the last mode it accepted for 33 h; the stale guard never armed
(0 of 133 cycles) because the self-heal reloads re-stamp its input (10-07 L3,
third time); the HA self-heal episode never started for the same reason; the
last-good SoC died with the process; the plans from an assumed 10 % published
37–41 EUR costs for 8 h; the recovery charge went in at the peak price into
the capacity guard; `JupiterLarSocUnknown` fired into `null`; the push-dead
notification was the only word to a human in 42 h; the lar's log rotation
erased the drop; the cause of the module drop is as unknown as on 10-05.

## What went well / what went poorly (blameless)

**Well:** the drain was bounded by the unit's own floor and the floor was
above the lar's `discharge_min_soc_pct` 20 % by only two points — luck, but
no deep discharge; the controller never commanded anything on a frozen or
unknown SoC; the cold start carried price and forecast from disk; the HA
archive and Prometheus let this review reconstruct the gap to the second
even with the lar's log gone; the first plan on a real SoC was an immediate,
sensible recovery charge and the guard cut it before the quarter blew.

**Poorly — lessons:**
- **L1:** a telemetry blackout is now a routine, multi-hour, multi-weekly event
  (six in four weeks, 1.4 h to 33 h) and it still pages nobody. *A dead feed
  needs a page within the hour — on a signal that a reload cannot fake
  (#333), routed somewhere a human reads (#250). The push-dead sensor was
  right for 33 h; use that class of signal, not a REST timestamp.*
- **L2:** a PASSTHROUGH *hold* during a cloud outage does not reach the unit.
  The battery discharged at the rack's load for 25 h under a command the
  controller had withdrawn at 08:30Z, until the unit's own floor stopped it
  and the rack went down with it. *The hold protects the controller's
  invariants, not the battery. When the feed dies while the unit is in
  DISCHARGING (or CHARGING), the controller must still try to put the unit in
  PASSTHROUGH — write it, retry it, and verify it when telemetry returns — and
  the hold must be bounded: no sample for N minutes is itself an actionable
  state, not a reason to wait (10-05 ADR-0029 D, 10-07 L4, now L2).*
- **L3:** the last-good SoC must survive a process restart. *An emptyDir
  turned a 25-h-stale 70 % into "unknown" and froze the controller for 8 h 40
  min; a persisted last-good with its timestamp would have let it hold on a
  known-stale value and plan something other than a 37 EUR recharge from 10 %.
  (Had the feed been alive at 09:05Z, the in-place restart would have cost
  nothing; the blind window was the feed's, the cold-start plan was the
  cache's.)*
- **L4:** #217/#309 (a local telemetry + command path) is the structural fix
  for the blackout; #331 (rack and vesta off the battery's AC output) is the
  structural fix for the outage. *Every other item in this review shortens
  the damage; only those two remove it.*
- **L5:** a self-heal that reloads on a fixed cadence must not feed the
  detectors that decide whether it is still needed. *Both the lar's stale age
  and HA's `bluetti_telemetry_stale` are re-stamped by the force-refresh
  reload; the episode automation's `for: 2 min` can never complete while the
  reload fires every 15 min. Key the episode and the escalation on
  `bluetti_push_dead` (or back the reload off once the placeholder never
  clears) — hestia.*
- **L6:** a cold start with no SoC should not publish a plan that prices a
  full recharge. *Plan from the last persisted SoC with its age, or publish
  "no plan" — a 37–41 EUR cost on the dashboards for 8 h is noise that hides
  the real signal (hephaestus; `JupiterLarPlanCostVolatile` fired for it).*

## Action items

- [x] Timeline, drain mechanism, rack-wide reboot, detector defeat and the
  #333 evidence established (this review)
- [ ] **#333 (atlas, in progress on `card-333`)** — evidence from this
  incident for the rule set, *not* a design: for the full 33 h
  `jupiter_lar_battery_telemetry_stale` = 0 and `battery_telemetry_age_seconds`
  cycled 20–610 s (< 900), so a rule on either is blind to a placeholder hold
  (10-14 showed the same: 0 stale minutes in a 90-min hold). Signals that
  were right: `jupiter_lar_ha_read_ok` = 0 throughout (both containers);
  `jupiter_lar_actual_mode_known` = 0 from 08:45Z 10-31 to 17:45Z 11-01;
  `increase(jupiter_lar_battery_placeholder_rejected_total{consumer="soc"}[1h])`
  = 4 for 33 h (one per cycle — a rising rejection counter *is* the
  placeholder hold); `jupiter_lar_battery_report_ages_push_seconds` frozen at
  985 from 08:40Z (frozen, not rising — a `changes()`-style test, not a
  threshold); `jupiter_lar_soc_unknown` = 1 only after the restart (09:05 →
  17:45Z); HA-side `binary_sensor.bluetti_push_dead` on 08:53Z → 17:41Z (not
  in Prometheus today). The `for` must outlast the 15-min reload cadence; the
  route must not be `null` (#250).
- [ ] hephaestus (new card): (a) **hold must write** — on a dead feed with the
  unit last known in DISCHARGING/CHARGING, command PASSTHROUGH, retry on a
  schedule, verify on the first real push (L2); (b) bounded hold: N minutes
  without a usable sample is an actionable state (10-07 L4); (c) **persist the
  last-good SoC** with its timestamp next to the price/forecast caches, and
  on rehydration hold on the stale value rather than "unknown" (L3); (d) a
  cold start with no SoC plans from the persisted SoC or publishes no plan
  instead of a 37–41 EUR recharge-from-10 % (L6); (e) the stale verdict must
  ignore placeholder re-stamps or key off push liveness (10-07 L3 — third
  occurrence); (f) pod log rotation: the previous container's log lost the
  morning of the drop — raise the containerd log limit for `jupiter-cell` or
  ship the log (atlas can own the limit)
- [ ] hestia (new card): (a) the self-heal *episode* and its 30-min/2-h
  escalation never started in 33 h because the force-refresh reload re-stamps
  `bluetti_telemetry_stale` (L5) — key them on `bluetti_push_dead` or back the
  reload off once the placeholder persists; (b) the push-dead notification
  must say what is at stake ("the battery is in <mode> and will keep doing
  it; the lar cannot stop it; expect the rack to drop at the floor") and
  repeat; (c) export `bluetti_push_dead` / `bluetti_report_ages` push age to
  Prometheus for #333; (d) the HA core restarts at 15:10:43, 15:17:02,
  15:20:23Z — cause?
- [ ] **#331 power topology (owner):** the rack and vesta rebooted because the
  battery reached its floor — the third outage from this coupling (10-05,
  10-07, 11-01); until it is fixed, every multi-hour blackout with the unit
  in DISCHARGING ends in a rack reboot
- [ ] #250 (atlas): route `severity=warning` jupiter alerts somewhere a human
  reads — `JupiterLarSocUnknown` fired 8 h into `null` today
- [ ] #342 (hestia): the Fluvius peak read has failed since 10-09; the guard
  ran November's first evening on October's 3.00 kW; confirm the November
  peak after today's 18:00–18:30Z quarters (≈ 2.5 kW from 1-min maxima)
- [ ] #217 / #309 (owner / hephaestus): a local telemetry + control path —
  sixth incident in four weeks with the same root
- [ ] Owner to confirm: was the app touched at 17:39–17:45Z on 11-01 (the
  `Time of Use` at 17:40:00Z), or at ~22:20Z on 10-30; what restored the
  module both times; did anything happen at the rack or the unit at ~09:02Z
  on 11-01; what is the unit's configured `Custom`-mode discharge floor
- [ ] clio: the 10-30 15:15 → 22:20Z blackout (7 h, self-heal escalation at
  22:00:45Z) is in the archive and unreviewed — fold it into the next feed
  review or the #319 cause work
- [ ] 10-07 open items unchanged: #319 (rehearse the WiFi-only route with the
  rack on bypass; app Bluetooth → Reset WiFi first), hestia self-heal
  escalation text ("power-cycle the battery"), the spike-override latch, the
  #178 subtrahend after a restart, HA export retry while InfluxDB is down,
  the ARP question

## Unverified

- The cause of the module drop (sixth time), and what restored it at
  17:39:36Z on 11-01 and at 22:20Z on 10-30; whether it dropped again at
  ~18:08Z for the same reason.
- That the ~09:02Z AC-output interruption was the unit reaching its discharge
  floor. Supporting: the SoC arithmetic (0.27 kW × 25 h = 52 points; 18 % at
  17:39Z after 8.5 h of no drain), the house-import step after 09:09Z, all six
  nodes and vesta booting together, no grid interruption on the HEM.
  Against: nothing direct — the unit's log is not reachable and the HEM
  itself was dark 09:04–09:08Z. A grid blip with a failed ride-through would
  look the same from here.
- Whether the ~08:30:10Z PASSTHROUGH write reached HA's select at all (no
  transition archived; the lar's log for that minute is rotated away) and
  whether the 09:05:34Z and 15:10–15:20Z writes left HA (accepted: yes; the
  unit still said `Custom` at 17:39Z: they did not take).
- Who set `Time of Use` at 17:40:00Z (a queued lar command delivered on
  reconnect, or the app).
- The cause of HA core's three restarts at 15:10–15:20Z.
- The exact instant of the cut: between the lar's last line 09:01:52Z and
  the first kubelet stamp 09:03:00Z; node boot times may be pre-NTP.
- November's billed peak (#342): the ≈ 2.5 kW quarter is from 1-min maxima,
  an upper bound.
- The 13.0 kWh usable capacity and the 1 point ≈ 0.13 kWh conversion are the
  site config's, not measured.

## Evidence (reproducible)

- Prometheus via the Grafana datasource proxy (`datasourceUid=prometheus`;
  Prometheus is distroless since #352, no `kubectl exec`), range queries
  unless noted: `jupiter_lar_soc_pct` (10-30 12:00 → 10-31 13:00Z step 600;
  10-31 07:30 → 09:30Z step 60; 10-31 10:00 → 11-01 19:30Z step 900);
  `jupiter_lar_actual_mode`, `jupiter_lar_actual_mode_known`,
  `jupiter_lar_soc_unknown`, `jupiter_lar_battery_telemetry_stale`,
  `jupiter_lar_battery_telemetry_age_seconds`,
  `jupiter_lar_battery_telemetry_liveness_override`, `jupiter_lar_ha_read_ok`,
  `jupiter_lar_ha_read_errors_total`, `jupiter_lar_target_charge_kw`,
  `jupiter_lar_target_discharge_kw`, `jupiter_lar_plan_cost_eur`,
  `jupiter_lar_mode_writes_total` (10-31 05:00 → 10:00Z step 900 for the
  last writes; 10-31 10:00 → 11-01 19:30Z step 3600),
  `jupiter_lar_mode_writes_suppressed_total`,
  `jupiter_lar_battery_placeholder_rejected_total` (step 300 around 08:40Z,
  step 3600 over the window), `jupiter_lar_battery_freshness_disagreement_total`,
  `jupiter_lar_battery_report_ages_push_seconds` (10-31 07:30 → 10:00Z step
  60); `jupiter_savings_today_eur`, `jupiter_reporting_soc_percent`,
  `jupiter_reporting_import_price_eur_per_kwh` (11-01 00:00 → 19:00Z step
  900), `jupiter_reporting_capacity_peak_kw`; `node_boot_time_seconds`
  (instant); `up{job=~"node-exporter|jupiter-cell|kubelet"}` and `count(up)`
  11-01 08:50 → 09:20Z step 15/30; `count(kube_pod_container_state_started >
  1793523700)` at 10:00Z; `sum(kube_pod_container_status_restarts_total)`
  08:00 → 10:00Z; `ALERTS{alertstate="firing"}` 10-31 10:00 → 11-01 19:30Z
  step 900 and `ALERTS{alertname=~"Jupiter.*|…"}` step 1800; the instant
  snapshot of the lar gauges at 18:34:26Z.
- lar logs: `kubectl -n jupiter-tervuren logs jupiter-cell-6b749d889d-7tp9g
  --previous` (rotated: 10-31 17:46:31 → 11-01 09:01:52Z, 22 696 lines) and
  the current container (09:05:33Z →, 10 384 lines at 18:23Z).
- kubectl: `get nodes -o wide/json` (Ready `lastTransitionTime`), `get pods
  -A -o json` (`lastState.terminated.{exitCode,reason,finishedAt}`,
  `state.running.startedAt`, per node), `get volumes.longhorn.io -n
  longhorn-system`, `get clusters.postgresql.cnpg.io -A`; `get events -A`
  (expired — nothing from 11-01 survives the 1 h TTL).
- HA archive, InfluxDB bucket `homeassistant` (read-only `influx query` in
  `influxdb-influxdb2-0`, org `zeus`): `office_buzzbrick_battery_level`
  (every point 10-30 00:00 → 11-01 19:30Z, change-collapsed; per-hour counts),
  `office_buzzbrick_ap3002532000565690_grid_input_power` and
  `…_alternating_current_out_power` (changes; 15-min means 10-30 22:00 →
  10-31 08:45Z excluding the placeholder value),
  `…_working_mode` (`state` field, all transitions 10-30 00:00 → 11-01
  19:30Z), `utility_room_home_energy_meter_electric_consumption_w` (15-min
  mean over the window; 1-min max 10-31 08:20–08:45Z, 11-01 08:50–09:20Z and
  17:30–18:40Z), all-entity write counts per minute / 5 min (11-01 08:55 →
  09:15Z, 09:00 → 18:30Z, 15:00 → 15:30Z, 18:15Z → now),
  `binary_sensor.bluetti_{integration_alive,push_dead,selfheal_episode,telemetry_stale}`
  transitions, `automation.bluetti_*` `last_triggered_str`,
  `sensor.bluetti_report_ages` `push_s` 10-31 08:00 → 09:00Z,
  `office_buzzbrick_*` last/first writes around 17:00Z on 11-01.
- gitops: `landingzones/jupiter-tervuren/values.yaml` (0.22.0;
  `usable_capacity_kwh` 13.0, `soc_min_pct` 10, `discharge_min_soc_pct` 20,
  placeholder signature, `battery_freshness_mode: enforce`, cache emptyDir
  comment), `landingzones/jupiter-tervuren/templates/prometheusrule.yaml`
  (`JupiterLarSocUnknown`, `for: 20m`), `.config/lab/observability.yaml`
  (Alertmanager route: default `null`, only `namespace="zeus"` →
  `ha-webhook`), `git log origin/master --since=2026-10-25` (no deploy in the
  window; last gitops release #519 on 10-25), branch `card-333` (133bb10).
- jupiter `jupiter-rel-0220`: `services/lar/jupiter_lar/clients.py`
  (price/forecast last-good persisted to `cache_path`), `ha_state.py`
  (`get_soc` degrades to last-good then `soc_min`; no persistence),
  `controller.py` (SoC-UNKNOWN hold #228; "holds the idle option until a
  real SoC is read").
- home-assitant `packages/bluetti_selfheal.yaml` 1.2.0 (one reload per 15
  min across both reload automations; episode automation `for: 2 min` on
  `bluetti_telemetry_stale`; `bluetti_push_dead` notify-only).

## References

gitops: this review; #456 (10-05 review); #458 (0.22.0 pins + freshness
enforce); #448 (mode-write alert rules); `card-333` (dead-feed alert rules, in
progress) · jupiter: ADR-0028 (placeholder guard, push-aware freshness),
ADR-0029 (mode-write discipline, D: bounded unknown-SoC hold), ADR-0032 ·
cards #331 #333 #342 #217 #309 #250 #319 #320 #228 #177 #178 #211 #213 ·
related: `2026-10-07-bluetti-wifi-drop-and-ac-power-cut.md` (open items #331
#332 #333 #334 #342), `2026-10-05-bluetti-wifi-drop-and-rack-power-cycle.md`,
`2026-09-12-bluetti-all-zero-freeze-and-reload-only-values.md`,
`2026-08-31-bluetti-staleness-deadlock.md` · home-assitant
`bluetti-selfheal.md`
