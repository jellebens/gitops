# Post-incident review — Bluetti all-zero freeze and "values only at a reload" (cards #306, #319, #320)

**Date:** 2026-09-12 → 2026-10-04 (two faces of one root cause: a ~22 h all-zero
freeze on 09-12/13, then 16 days of reload-only telemetry 09-18 → 10-04) ·
**Severity:** medium (lost optimization, wrong data on the kiosk, a control loop
running on reload-polled values — no safety exposure at any point) · **Status:**
resolved on vesta by an owner-applied hand patch to the third-party integration
(upstream unfixed) + self-heal 1.1.0/1.2.0 + lar 0.20.0; freshness enforcement
and the HACS-update risk still open · **Format:** blameless SRE-style postmortem
with an A3-style summary box. All times **UTC** (local = UTC+2).

---

## A3 summary (one-box view)

| | |
|---|---|
| **Background** | The lar reads the battery over HA REST from the official Bluetti cloud integration (`bluetti-official/bluetti-home-assistant`). In cloud mode nothing polls: values arrive once at integration setup and on every websocket push. The HA package `bluetti_selfheal` (#212/#259) reloads the integration when values sit unchanged, and the lar holds PASSTHROUGH on stale (#211) or implausible (#214) telemetry. |
| **Problem** | **Face A (09-12 22:50 → 09-13 ~21:00):** HA served SoC 0 with fresh timestamps; the lar held PASSTHROUGH ~22 h, charging suppressed, savings €0.02 for the day; the kiosk showed a phantom "charging" mode. **Face B (09-18 09:16 → 10-04 17:27):** all four battery entities were frozen between integration reloads — the whole control loop ran on telemetry refreshed only by the self-heal's own reloads (~178/day), the spike path was starved ~80 % of the time, and each reload briefly published a placeholder snapshot (51 % / 2008 W / 607 W) that the lar treated as a fresh measurement. |
| **Direct cause** | The push channel was dead, so the only fetch left was the one at integration setup. Face A: that fetch returned zeros from the cloud (the unit's IoT module in its known "crash → spurious 0" state). Face B: that fetch returned real values, so every reload "worked" and nothing looked wrong. |
| **Root cause** | `BluettiData.web_socket_message_handler` (`models.py` line 66, integration v1.0.3–v1.0.5) reads `res["data"]["message"]["deviceSn"]`; the cloud sends the serial at `data.deviceSn`, so **every push raises `KeyError('message')`**, swallowed by `StompListener.__callback`. The socket stays up, no read is scheduled, nothing recovers. Introduced upstream in commit ba9e7fc (08-27). The self-heal masked it: a reload re-fetches values and re-stamps every REST timestamp, so every detector (lar #211, `bluetti_integration_alive`, force-refresh) reported healthy. |
| **Countermeasures** | (1) Owner hand-patched the handler on vesta to accept both frame shapes (2026-10-04 17:27Z; `patches/bluetti-1.0.5-ws-handler-both-shapes.patch`, upstream issue #176). (2) `bluetti_selfheal` 1.1.0: 10-min threshold floor, one shared reload budget, no reload cap, duration-keyed owner escalation, `sensor.bluetti_report_ages`. (3) `bluetti_selfheal` 1.2.0: `push_s` + `binary_sensor.bluetti_push_dead` (notify-only). (4) lar 0.20.0 (#320, ADR-0028): reject the placeholder triple at the single read choke point; push-aware freshness in **observe** mode. |
| **Verification** | 10-04 17:28:54Z: first value change without a reload since 09-18; **0 reloads** 17:27 → 00:40Z next day, 6 in the following 21 h (was ~170/day); HA log free of `error from callback … 'message'` (owner, 17:50Z); AC-out changed 411× in the next 21 h. lar 0.20.0 rejected the 10-05 15:15:06Z placeholder (PASSTHROUGH for one cycle, planned from last-good 76 %) — counters `jupiter_lar_battery_placeholder_rejected_total{consumer}` soc 1 / spike_sample 18 / measured_mode 19 / house_load 1 by 18:30Z. |
| **Follow-up** | `battery_freshness_mode` observe → enforce (owner-gated); the patch is unmanaged on vesta — **a HACS update silently reverts it**; `push_s` under-count in self-heal 1.2.0; #267 (optional `ac` read); #250 (jupiter alerts route to null); the HA→InfluxDB archive gaps 09-13 21:00Z → 09-15 13:00Z and 09-30. |

---

## Impact

- **Face A — 2026-09-12 22:50:05Z → 2026-09-13 ~21:00Z (~22 h):** HA served
  SoC 0 at every 15-min reload; from 03:10:08Z grid-in and AC-out read 0 too.
  The lar's #214 plausibility guard held PASSTHROUGH throughout — the planned
  charge was suppressed for ~21 h and the day's savings read **€0.02** (card
  #306, from Prometheus at the time; outside today's 15-day retention). The real
  SoC during the hold is unknown (the unit was fine; the lar's last real reading
  was 71 % at 22:45:05Z). The kiosk mode tile showed a phantom "charging" from
  the frozen grid-in value (`measured_mode_code` had no freshness gate).
- **Face B — 2026-09-18 09:16Z → 2026-10-04 17:27Z (16 d 8 h):** the control
  loop ran on values refreshed only by integration reloads: longest sample gap
  ~15 min; the spike responder (#177/#178, 150 s freshness gate) had no usable
  grid-in sample on 80–84 % of its cycles every hour; the kiosk mode tile was
  computed from stale grid-in. Each reload published the placeholder snapshot
  (SoC 51 %, grid-in 2008 W, AC-out 607 W, mode "Backup") with a fresh
  timestamp: >5 s in 52 of ~1 750 reloads, >1 min in 5, 89 min once. On 10-04
  15:10:05 → 15:11:51Z (106 s) the lar treated placeholder grid-in 2008 W as
  fresh; a live spike DISCHARGE override at 15:12:05Z may have used one such
  sample (unverifiable from the log). Daily savings in the window stayed
  €0.47–1.27 (except 09-29, €0.01, which coincides with an archive gap) — **no
  collapse**, so the cost of Face B is small but unquantified.
- **Operational load:** ~178 integration reloads/day (each stalls HA ~5 s)
  before 1.1.0; the #212 automation reloaded on a false "freeze" ~90×/day
  because the live stale threshold was 1 min, not the intended 5.
- **Evidence loss:** the HA→InfluxDB archive is dark 09-13 ~21:00Z → 09-15
  ~13:00Z (and on 09-30); cause not established.
- **Safety exposure:** none — every failure mode degraded to the conservative
  hold; no actuation on a 0 % or 51 % SoC was ever commanded.

## Timeline (UTC)

### Face A — the all-zero freeze

| Time | Event |
|---|---|
| 09-12 06:42 | First "values only at reloads" onset in the archive (hestia, #319). No version change on vesta coincides with it. |
| 09-12 ≤18:00 | Reload-only state present hours before the freeze (card #319). |
| 09-12 22:45:05 | Reload: placeholder 51 %, then real **71 %** — the last real SoC before the freeze. |
| 09-12 22:50:05.69 | Reload: placeholder 51 %, then **0**. SoC reads 0 at every reload from here. Grid-in 654 W / AC-out 653 W still served — neither all-zero nor stale, so invisible to every detector for 4 h 20 min. |
| 09-13 00:25:01 | #212 reload automation hits its cap of 4 and stops. `bluetti_force_refresh_values` keeps reloading every 15 min (86 reloads over the incident, each re-fetching the same zeros). |
| 09-13 00:30:01 | #246 "stuck" notification fires **once** — persistent notification only (the phone push was commented out), by accident via the flapping stale detector. Nothing re-notifies. |
| 09-13 02:55:05 | Last non-zero grid-in / AC-out (654 W / 653 W). |
| 09-13 03:10:08 | Grid-in and AC-out → **0**: the all-zero detector turns on. |
| 09-13 ~16:30 | One 51 % blip (a placeholder) — the owner notices the frozen kiosk by hand. |
| 09-13 ~20:00 | Card #306 opened. |
| 09-13 ~21:00 | Owner recovers the integration (comms reload / power-cycle at the unit); a partial freeze follows (grid-in frozen ~21:14 while SoC/AC-out update). The HA→InfluxDB archive goes dark at ~21:01Z. |
| 09-13 21:25 | Two lar/HA defects filed on #306: `measured_mode_code` has no staleness check; both self-heal automations key on the MIN age over four entities, so one live entity defeats them. |
| 09-15 ~13:00 | Archive returns. Values healthy 09-15 12:25 → 09-18 09:15. |

### Face B — values only at a reload

| Time | Event |
|---|---|
| 09-18 09:16 | Second onset: from here every value arrives only at a reload. AC-out writes/day in the archive: 1 922 (09-18) → 877 (09-19) → 100 (09-20) → ~165–340/day until 10-04. Coincides to the minute with upstream issue #168 (another user's stations dropped at 09:14Z that morning). |
| 09-20 17:04 | Integration v1.0.5 installed (v1.0.3 08-31, v1.0.4 09-02). All three carry the same handler line — no effect. |
| 09-30 | The owner's own HA log shows `KeyError: 'message'` from the handler (quoted in upstream issue #176, opened by the owner). |
| 10-04 11:01 | Battery check: the lar's spike path logs `grid-input STALE (age > 150s)` on 236–304 of 360 cycles **every** hour — chronic, not incident-only. |
| 10-04 11:42 | hestia (#306) reconstructs both faces from the archive; four of the card's premises were wrong (see 5-whys). `bluetti_selfheal` 1.1.0 PR #34; the reload-only finding becomes card #319. |
| 10-04 14:27:30 | 1.1.0 active on vesta (an earlier restart attempt at 12:08Z did not take). Threshold = 10 min; `bluetti_integration_alive` on 100 % (was 29–38 %). |
| 10-04 15:10:05 → 15:11:51 | A reload placeholder stands 106 s; the lar reads 2008 W as fresh. 15:12:05: live spike DISCHARGE override 2.18 kW (SoC 97 %, probably a genuine house spike). |
| 10-04 15:24 | hestia (#319): **root cause found** — the `KeyError` in the push handler. PR #35: self-heal 1.2.0 + the patch file + runbook §2e. Nothing written to vesta. |
| 10-04 17:22 | Owner "go": PR #35 merged (a3d1001), 1.2.0 deployed to vesta. The models.py patch is **not** applied by any agent — the permission system refused the remote write and nobody worked around it. |
| 10-04 ~17:27 | Owner pastes the 7-line block by hand and restarts HA. 17:27:52 startup placeholder, then real values (85 %). **17:28:54: first value change without a reload since 09-18.** |
| 10-04 17:45–17:48 | 0 reloads since the restart; alive 100 %. The 1.2.0 push detector misses some changes (`push_s` under-count) — follow-up. |
| 10-04 17:50 | Owner: HA log clean, no `error from callback` for bluetti. |
| 10-04 18:44–18:47 | lar **0.20.0** released and deployed (#320): placeholder guard armed with signature (51, 2008, 607); push-aware freshness in observe mode. 18:48:09: first observe-mode disagreement logged ("REST says STALE but the feed is demonstrably ALIVE"). |
| 10-05 00:40 → 12:28 | 6 reloads in 21 h (was ~170/day). Patch held. |

## Causal chain (5-whys)

1. **Why no charge on 09-13?** The #214 plausibility guard held PASSTHROUGH: SoC
   read 0 from 22:50Z, and from 03:10Z all three readings were 0.
2. **Why did HA serve zeros?** The only fetch still running — the one at
   integration setup — returned 0 from the Bluetti cloud (the unit's IoT module
   in its known "crash → spurious 0" state). Every 15-min reload repeated it.
3. **Why was setup the only fetch?** The websocket push handler raised
   `KeyError('message')` on every frame (`data.message.deviceSn` vs the real
   `data.deviceSn`), swallowed by the STOMP listener; the socket stays up, no
   reconnect, no read. Upstream bug since v1.0.3 (commit ba9e7fc, 08-27);
   v1.0.4 and v1.0.5 identical. Why the push stream only *started* failing on
   09-12 and again 09-18 is inferred, not proven: a cloud-side frame change
   (upstream #168 timing) — see "unverified".
4. **Why didn't the self-heal cure it?** Four premises of card #306 were wrong,
   and the archive showed it: (a) force-refresh *did* fire every 15 min — 86
   reloads, each re-fetching the same zeros; (b) the #212 cap of 4 was spent by
   00:25Z; (c) the live stale threshold was **1 min** (the `input_number` had
   no `initial`, so it started at `min`) → the stale detector was on 62–71 % of
   the time and masked everything with ~90 false reloads/day; (d) the "reports
   every 300 s" are not telemetry — any write to a Bluetti select/switch makes
   the integration re-write all entities with the values it already holds, so a
   dead push channel is invisible to any timestamp-based detector.
5. **Why did Face B run 16 days unnoticed?** Reload-polling kept the control loop
   alive and every REST timestamp fresh; the only symptoms were a chronic
   `grid-input STALE` in the spike path, a lower write rate in the archive, and
   a kiosk mode tile that was sometimes wrong. The #246 notification fired once
   with no push; jupiter alerts route to null (#250); nobody was paged.

**Aggravating factors:** the reload **placeholder** (51 % / 2008 W / 607 W,
fresh timestamp) — the lar had no defence against a value that is not a
measurement; the detectors keyed on MIN age across entities (a partial freeze
keeps min≈0); the archive gap 09-13 → 09-15 that hid the recovery.

## Resolution — what was deployed

1. **Owner hand patch on vesta** (`/config/custom_components/bluetti/models.py`
   lines 66–77, 2026-10-04 17:27Z): the handler accepts both frame shapes.
   Permanent for this host, **but unmanaged**: an integration update via HACS
   restores the upstream file. Reference checksum of the patched file on vesta:
   sha256 `d107921a…` (the owner kept the original line as a comment, so it
   differs from the documented `cfe58a38…`). Patch file:
   `home-assitant/patches/bluetti-1.0.5-ws-handler-both-shapes.patch`; runbook
   `bluetti-selfheal.md` §2e; upstream issues #171, #172, #176 (all open).
2. **`bluetti_selfheal` 1.1.0** (home-assitant PR #34, ddf2d41; active 10-04
   14:27Z): stale threshold min 1 → 10 min with a template floor; one shared
   reload budget (≤1 reload / 15 min); the cap of 4 removed — 15-min reloads for
   the first hour of an episode, then hourly, forever; escalation keyed on
   episode duration (persistent + phone push at 30–35 min, every 2 h after, a
   "recovered after …" at the end); `sensor.bluetti_report_ages` (per-entity
   `last_reported` / `last_updated` ages, `now()`-driven);
   `binary_sensor.bluetti_telemetry_soc_zero`, `…_partial_freeze` (observe-only
   behind `input_boolean.bluetti_partial_freeze_enforce`), `…_selfheal_episode`.
3. **`bluetti_selfheal` 1.2.0** (home-assitant PR #35, a3d1001; active 10-04
   17:27Z): `sensor.bluetti_last_push_update`, `push_s` on the report-ages
   sensor, `input_number.bluetti_push_dead_threshold_minutes` (30),
   `binary_sensor.bluetti_push_dead` (notify-only) + notify/dismiss automations.
   Additive — nothing existing changed behaviour.
4. **lar 0.20.0** (#320; jupiter PR #134 → v0.20.0 tag 85de131, changelog #137;
   gitops #445 values + #446 release; **ADR-0028** "a REST timestamp is not
   evidence of a measurement"): placeholder guard at the single read choke point
   `LiveState.battery_snapshot()` — a snapshot matching a configured signature is
   "no sample" for every consumer (planner → last-good SoC; controller →
   PASSTHROUGH hold for that cycle; spike sample → none; `measured_mode_code` →
   None with `jupiter_lar_actual_mode_known = 0`; house-load → not banked).
   Push-aware freshness (`off` / `observe` / `enforce`) via
   `sensor.bluetti_report_ages`, shipped **observe** on tervuren. Metrics
   `jupiter_lar_battery_placeholder_rejected_total{consumer}`,
   `jupiter_lar_battery_report_ages_ok`, `…_freshness_disagreement_total`.
5. **Unchanged final nets:** #211 stale hold, #214 plausibility guard, #259
   liveness override — all three held through both faces.

Reverted: nothing. (The #212 cap of 4 was removed by design, not reverted.)

## What went well / what went poorly (blameless)

**Well:** the #214 guard held both times — the lar never actuated on a 0 % or
51 % SoC. The HA archive in InfluxDB (bucket `homeassistant`) made a
to-the-minute reconstruction possible weeks later, and reading it *first*
overturned four wrong premises before any fix was coded. The root cause was
proven three ways (unmodified v1.0.5 source with no polling path, the owner's
own log line, a replay of the real frame against both handlers) and the patch
was verified live within two minutes of the restart. The permission system
refused an agent's remote write to vesta and the agent surfaced it instead of
working around it. The owner had already filed upstream #176.

**Poorly — lessons:**
- **L1:** Every detector keyed on a REST timestamp, and a reload re-stamps every
  timestamp. *A fresh timestamp is not a measurement; gate on evidence that a
  value was produced (ADR-0028).*
- **L2:** Self-heal by reload kept the control loop alive for 16 days and hid
  the dead push channel from every monitor. *A masking remedy needs its own
  "am I masking?" signal — `push_dead` / `push_s` exist now.*
- **L3:** A capped retry (#212, 4 attempts) plus a single un-pushed
  notification (#246) plus alerts routed to null (#250) equals a silent 21 h
  outage found by eye. *Escalation must be keyed on duration and must reach a
  human.*
- **L4:** One line in an unmanaged third-party integration cost 16 days, and
  the fix is a hand edit that the next HACS update erases. *Pin and checksum
  third-party code on vesta; keep moving to a local control path (#217 / #309).*
- **L5:** The incident card's gaps were written from the symptom, not the
  record (force-refresh "never trips" — it tripped 86 times). *Verify premises
  against the archive before designing the fix.*
- **L6:** An `input_number` without `initial` started at `min` = 1 min and
  produced ~90 false reloads/day for a month. *Defaults that gate safety logic
  must be explicit and asserted after deploy.*

## Action items

- [x] `bluetti_selfheal` 1.1.0 (home-assitant #34) and 1.2.0 (#35) on vesta, active 10-04
- [x] Handler patch applied on vesta by the owner (10-04 17:27Z); patch file + runbook §2e in the repo
- [x] lar 0.20.0 + tervuren `ha:` values (jupiter #134/#136, gitops #445/#446), ADR-0028, CHANGELOG v0.20.0 (jupiter #137)
- [x] Upstream issue #176 (owner); #171/#172 related — open, no maintainer reply
- [ ] Flip `battery_freshness_mode` observe → enforce after observe data across a charge start/stop; consider `battery_measured_mode_max_age_seconds: 150` (#320 follow-up, owner-gated)
- [ ] HACS-update risk: a checksum watch on `models.py` (patched = `d107921a…` on vesta) or a HA-side check; evaluate the community fork 1.5.5 / BLE (#217) / Modbus TCP (#309) as the way out (hestia / owner)
- [ ] `push_s` under-count in self-heal 1.2.0: `bluetti_last_push_update` skipped the 17:29:17, 17:29:54 and 17:47:56Z changes on 10-04; `bluetti_push_dead` inherits it and false-fired once (10-05 02:17–02:22Z) (hestia)
- [ ] argus: grey the kiosk mode tile on `jupiter_lar_actual_mode_known == 0`
- [ ] Decide `input_boolean.bluetti_partial_freeze_enforce` — note hestia's later finding that a partial freeze cannot occur with this integration (every fetch is a full fetch)
- [ ] #267 — `ac` as an optional read (unchanged by this arc)
- [ ] #250 — jupiter alert routing (alerts route to null); #249 — home-assitant CI
- [ ] Archive gaps 09-13 ~21:00Z → 09-15 ~13:00Z and 09-30: cause not established (hestia / atlas)
- [ ] Findings beyond the cards: `automation.update_apex_300_working_mode` writes its state ~27 000×/day into recorder + InfluxDB; the retired `packages/bluetti_battery_economics.yaml` is still on vesta (hestia, uncarded)
- [ ] The 2026-08-31 action item "PrometheusRule on `jupiter_lar_battery_telemetry_stale == 1` sustained >30 min" is still open and would have caught Face A

## Unverified

- The 09-18 trigger (a Bluetti cloud-side frame change) is inferred from the
  upstream #168 timing; the cause of the first onset 09-12 06:42Z → 09-15 is not
  established (upstream #165 documents a second route: websocket drops with no
  working reconnect).
- Whether the 10-04 15:12:05Z spike override used a placeholder-corrected sample.
- The 09-13 savings figure (€0.02) is taken from card #306; Prometheus no longer
  holds that day.
- The cause of the archive gaps (09-13 → 09-15, 09-30).

## Evidence (reproducible)

- HA archive, InfluxDB bucket `homeassistant`, read-only `influx query` in
  `influxdb-influxdb2-0`: entity `office_buzzbrick_battery_level` 09-12
  22:40–23:10Z (71 at 22:45:05.62, 0 from 22:50:05.69); entities
  `…_grid_input_power` / `…_alternating_current_out_power` 09-13 02:50–03:30Z
  (654/653 W at 02:55:05, 0/0 from 03:10:08); `aggregateWindow(every: 1d, fn:
  count)` on AC-out 09-08 → 10-06 (2 009 / 771 / 170 / 0 / 996 / 2 002 / 1 922 /
  877 / 100 / 165 / 327 … 295); SoC hourly counts 09-13 18:00 → 09-15 14:00Z
  (last samples in the 21:00Z hour, first in the 13:00Z hour).
- Prometheus (`svc/kube-prometheus-stack-prometheus`): `max(jupiter_savings_today_eur)`
  range 09-21 → 10-05 at 21:50Z step 86400 (€1.27, 0.73, 0.66, 1.00, 1.19,
  0.84, 0.47, 0.87, 0.01, 0.24, 0.39, 0.63, 0.59, 0.90, −0.14);
  `sum by (consumer) (jupiter_lar_battery_placeholder_rejected_total)` 10-05
  14:00 → 19:00Z step 1800.
- Trello #306 (`6aa700b0ab61b321c0ad735a`), #319 (`6ac23c01627490ba21ed1b6f`),
  #320 (`6ac26fc4d23758db623c7ff9`) comments; home-assitant `main` a3d1001;
  jupiter `docs/adr/0028-rest-timestamp-is-not-evidence-of-a-measurement.md`.

## References

home-assitant PRs #34 (self-heal 1.1.0, ddf2d41), #35 (1.2.0 + patch file +
runbook §2e, a3d1001) · jupiter PRs #134 (lar 0.20.0), #135 (`pulp<4` pin),
#136 (release v0.20.0), #137 (changelog) · gitops PRs #445 (tervuren values),
#446 (release) · upstream `bluetti-official/bluetti-home-assistant` issues #165,
#168, #171, #172, #176 · cards #306 #319 #320 #212 #214 #246 #250 #259 #267
#217 #309 · ADR-0028 · runbook `home-assitant/bluetti-selfheal.md` §2e ·
related: `2026-08-31-bluetti-staleness-deadlock.md`,
`2026-10-05-bluetti-wifi-drop-and-rack-power-cycle.md`
