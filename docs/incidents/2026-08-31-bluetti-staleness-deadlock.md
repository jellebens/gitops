# Post-incident review — Bluetti idle-staleness deadlock (card #259)

**Date:** 2026-08-30 → 2026-08-31 · **Severity:** medium (no safety risk; lost
optimization + one unwanted discharge) · **Status:** resolved, fixes deployed &
proven · **Format:** blameless SRE-style postmortem with an A3-style summary box.

---

## A3 summary (one-box view)

| | |
|---|---|
| **Background** | The lar (live battery controller) reads Home Assistant over REST and refuses to actuate on "stale" telemetry (#211 guard, 900 s) — a deliberate safety hold. |
| **Problem** | The guard false-fired on every *idle* stretch: valid charge plans were suppressed for hours ("why are you not charging"); on 08-30 the same mechanism deadlocked the spike responder into a 2.5 h unwanted discharge (SoC 66→58 %). Kiosk/report showed stale values. |
| **Direct cause** | HA only **rewrites a state (bumping REST `last_updated`) when the value changes**. An idle battery's readings are constant ⇒ all REST timestamps freeze ⇒ the feed is indistinguishable from dead ⇒ guard holds ⇒ holding keeps values constant ⇒ **self-sustaining deadlock**. |
| **Root cause** | HA's REST `/api/states` serves a **cache-frozen `last_reported`** (built once per state object; the live ~13 s coordinator heartbeat mutates the object without rebuilding the cached JSON). No REST-visible timestamp can discriminate *idle-but-live* from *dead*. Only HA's **template engine** sees the true heartbeat. |
| **Countermeasures** | (1) HA-side `bluetti_force_refresh_values` automation: reload the Bluetti config entry when values sit unchanged >10 min — recreated entities get fresh REST timestamps. (2) lar v0.18.4 liveness override: guard reads `binary_sensor.bluetti_integration_alive` (template-computed) instead of timestamps. (3) The sensor's `now()`-driven `heartbeat` attribute keeps *its own* REST timestamp fresh (load-bearing — never remove). |
| **Verification** | 2026-08-31 ~19:00: the integration wedged at HA boot (age 2226 s, stale=1); the package self-healed with **zero human action** — age→402 s, stale→0, real SoC 58 % surfaced (frozen value had read 53 %). |
| **Follow-up** | `battery_stale_max_hold_seconds` interim blind timer reverted to 0 (gitops #309/#310). Watch one quiet overnight. Trello board sync pending (MCP outage). |

---

## Impact

- **Lost optimization:** charge plans suppressed during idle stretches on
  08-30/08-31 (bounded by manual interventions; savings impact small but real).
- **08-30:** 2.5 h unwanted discharge (spike-responder variant of the same
  deadlock), SoC 66→58 %.
- **Wrong data:** kiosk/report showed frozen SoC/power values (e.g. 53 % shown
  vs 58 % real).
- **No safety exposure at any point** — every failure mode degraded to the
  conservative hold, never to blind actuation.

## Timeline (2026-08-31, local)

| Time | Event |
|---|---|
| ~15:5x | "Why are you not charging" — lar logs `plan intent 'charging' suppressed`, stale hold, SoC frozen at 47 %. |
| ~16:00 | Pod restart attempted — **did not clear** (guard reads HA, not pod state) → proves guard logic, not a stuck process. |
| ~16:00–17:00 | Owner confirms integration alive in HA; `last_updated == last_changed` frozen (constant value). Owner: "if it's in idle it won't change." Correct. |
| 17:15 | v0.18.3 deployed (guard keyed on REST `last_reported`) — **insufficient**: REST serves it cache-frozen. |
| 17:2x | `battery_stale_max_hold_seconds: 300` stopgap deployed — releases the false hold; charging resumes (46→53 %). |
| 18:1x | v0.18.4 deployed (liveness-entity override) + HA-side alive sensor — override still 0: the sensor's own REST timestamp froze (no `now()` in its template) → the lar's anti-wedge freshness gate refused it. Two halves built separately didn't mesh. |
| ~17:52 | Separately: integration **genuinely froze mid-charge** (its chronic wedge). |
| 18:5x | Final fix merged (home-assitant #11): `now()`-driven `heartbeat` attribute + `bluetti_force_refresh_values` automation. Owner applies to vesta, restarts HA. |
| ~19:00 | Integration wedges again at HA boot → **package self-heals in ≤4 min, no human action** (age 2226→402 s, stale→0). PASS. |
| 19:3x | `max_hold` stopgap reverted (release #310). Runbook §2c + CHANGELOG (jupiter #127) updated. |

## Causal chain (5-whys)

1. **Why no charge?** The #211 staleness guard held PASSTHROUGH and suppressed the plan.
2. **Why did the guard fire?** REST `last_updated` of every battery entity was >900 s old.
3. **Why were the timestamps frozen?** HA only rewrites a state when the **value** changes; an idle battery's values are constant. (The Bluetti cloud integration also only *reports* on change.)
4. **Why couldn't the guard use the poll heartbeat instead?** HA REST serves a **cache-frozen `last_reported`** — the ~13 s heartbeat mutates the live state object without rebuilding the cached REST JSON. v0.18.3 keyed on a field that cannot move over REST.
5. **Why did it self-sustain?** Holding PASSTHROUGH keeps the battery idle ⇒ values stay constant ⇒ timestamps stay frozen ⇒ guard stays held. Only an external value change (manual charge, integration reload, HA restart) could break the loop — each bought exactly one ~15-min window.

**Aggravating factor:** the integration also *genuinely* freezes (wedge at HA
boot, mid-operation stalls) — two failure modes with identical REST signatures,
which is why availability- or timestamp-only checks kept failing.

## Resolution — the deployed defense-in-depth

1. **`bluetti_force_refresh_values`** (HA package, vesta): reload the config
   entry when battery values sit unchanged >10 min. Fresh entities ⇒ fresh REST
   timestamps ⇒ the 900 s guard can never trip on idle; doubles as unwedging a
   frozen poller. *Primary mechanism, proven live.*
2. **lar v0.18.4 liveness override** (`ha.battery_liveness_entity` →
   `binary_sensor.bluetti_integration_alive`): the template engine sees the true
   heartbeat; the sensor exposes it as an on/off **state value**, which REST
   serves correctly. Strict positive confirmation — any doubt keeps the hold.
3. **`heartbeat` attribute** on the alive sensor (`now()`-driven, changes every
   minute): keeps the sensor's *own* REST timestamp fresh so the lar's 300 s
   anti-wedge gate can pass. **Load-bearing — removing it recreates the
   recursion (override permanently 0).**
4. **#211 hold** remains the final safety for genuine freezes (alive sensor
   flips off ⇒ no override ⇒ hold), with the capped #212 reloader + #246
   power-cycle escalation on top.

Reverted: the interim `battery_stale_max_hold_seconds: 300` blind timer (would
also have released a *genuine* freeze onto a frozen SoC).

## What went well / what went poorly (blameless)

**Well:** conservative-by-design guard meant zero unsafe actuation throughout;
fast iteration (3 releases + HA package in one evening); the owner's
observations ("it won't change when idle", "responsive when I push an update")
pinpointed the mechanism; final fix verified by a live, unplanned wedge.

**Poorly — lessons:**
- **L1:** v0.18.3 keyed safety logic on an API field (`last_reported` over REST)
  whose behaviour was assumed, not verified. *Empirically validate API field
  semantics before keying safety logic on them.*
- **L2:** The v0.18.4 lar gate and the HA sensor were built by separate agents
  against each other's assumptions and didn't mesh (gate needed a re-stamping
  sensor; sensor didn't re-stamp). *Cross-repo contracts need an explicit
  integration check before deploy.*
- **L3:** Restart-first instinct wasted a cycle (pod restart can't fix a
  guard reading external state). *Localize the state a guard reads before
  restarting things.*
- **L4:** Shell quoting through WSL corrupted a release command (empty PR
  variable → merge attempted on the wrong, already-merged PR; harmless no-op
  but caught only by explicit re-verification). *Script files + verify PRs by
  number, always.*

## Action items

- [x] Force-refresh automation + heartbeat attr shipped & applied (home-assitant #11, on vesta)
- [x] lar v0.18.4 deployed, liveness entity wired (gitops #307/#308)
- [x] `max_hold` stopgap reverted (gitops #309/#310)
- [x] Runbook §2c (home-assitant #12), CHANGELOG v0.18.3+v0.18.4 (jupiter #127)
- [ ] One quiet overnight of observation (no stale-suppressed episodes)
- [ ] Trello board sync for the #259 arc (MCP was down)
- [ ] Consider: PrometheusRule alert on `jupiter_lar_battery_telemetry_stale == 1` sustained >30 min (ties into the #250 alert-routing gap)

## References

jupiter PRs #123/#124 (v0.18.3), #125/#126 (v0.18.4), #127 (changelog) ·
gitops PRs #305/#306 (stopgap), #307/#308 (liveness deploy), #309/#310 (revert) ·
home-assitant PRs #10 (alive sensor), #11 (heartbeat + force-refresh), #12
(runbook §2c) · cards #211 #212 #214 #246 #256 #259 ·
runbook: `home-assitant/bluetti-selfheal.md` §2c
