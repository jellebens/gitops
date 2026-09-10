# #278 — Demeter: the k3s autodosing brain (auto-feed + pH stabilisation)

Status: **live — ACTIVE in lab** since 2026-09-10 (chart 0.3.1, image
`jellebens/pomona-demeter:0.1.0`; card #278 closed). Design of record for the
rails remains pomona card **#224**; this document records the k3s half —
what runs in-cluster, why the split is safe, and the rollout gates.

## Goal

Close the loop the monitoring-first phase deliberately left open: keep the
reservoir's pH inside 5.8–6.2 with pH-Down, and its EC inside the crop band
with Nutrients A+B — automatically, observably, and inside hard safety
rails. Replaces the interim **Tethys** regime (an hourly Claude scheduled
agent dosing via `pomona/dose/test` under an owner grant), which only runs
while the desktop app is open — the cluster brain runs always.

## The architecture decision — cluster brain, firmware veto

`pomona/docs/control-architecture.md` argued pump/light *scheduling* belongs
on the GIGA ("whoever holds the sensor holds the cutoff"), and #224's note
suggested dosing land there too. The owner decided (2026-09-10) the dosing
brain lives on k3s instead, instructing the unit over MQTT. That is a
different — and defensible — trade than irrigation:

- **Fail-safe direction.** A dead irrigation loop kills the crop in days,
  so irrigation must survive network loss. A dead *dosing* loop just skips
  doses — pH drifts for a day and a human or the next cycle corrects it.
  For dosing, "do nothing when uncertain" is exactly right, and a cluster
  outage produces precisely that.
- **The danger is over-dosing, and the firmware keeps that veto.** Every
  command Demeter can send goes through the bench module's rails: 10 s hard
  cap per run (`DOSE_TEST_MAX_MS`), one channel at a time, explicit stop
  state at boot. A misbehaving controller cannot run a pump continuously.
  The #224 firmware follow-up deepens this veto (ml caps + daily budget in
  firmware).
- **The loop is slow and stateful.** Confirm windows, 60-min lockouts,
  rolling 24 h budgets, cross-restart ledgers, Prometheus history — that is
  cluster-shaped state, awkward on a microcontroller that reboots for OTA.

Principle, restated for dosing: *the firmware holds the pumps and the caps;
the cluster holds the chemistry judgment and can only make small, bounded
requests.*

## What ships

| piece | where |
|---|---|
| Demeter service (`jellebens/pomona-demeter`, arm64) | pomona repo `controller/` — decision engine + MQTT runtime + Prometheus, engine unit-tested |
| Chart: deployment / configmap / sealed-secret / service / servicemonitor / CNP | `landingzones/pomona/templates/demeter-*.yaml` |
| Playbook config (bands, quanta, caps, DFR0523 calibration) | `landingzones/pomona/values.yaml` `demeter.config` |
| Broker user `pomona-demeter` (least privilege) + DR mirror | owner runbook in the landing-zone README; `platform/mqtt/files/acl.conf` |
| MQTT contract (`pomona/demeter/*`, dose channel) | pomona repo `docs/mqtt.md` "Dosing topics" |

The rails are the Tethys playbook, verbatim (see the landing-zone README's
Demeter section for the table). The engine's computed dose timings
independently reproduce the hand-calibrated ready timings (2083/4545/7576/
8333 ms vs 2080/4550/7580/8330) — the calibration constants and the math
agree.

## Rollout gates (owner-controlled, one per release)

1. **Ship in shadow** — ✅ done 2026-09-10, chart 0.3.0: Demeter evaluates
   live water, publishes `pomona/demeter/decision` and `demeter_would_dose`,
   doses nothing. Owner pre-deploy done: `pomona-demeter` EMQX user created,
   creds sealed in `.config/lab/pomona.yaml`, arm64 image 0.1.0 pushed.
2. **Shadow soak** — ⏭ **skipped by owner decision** (2026-09-10). The plan
   was some days comparing Demeter's decisions against Tethys's Trello dose
   log; the rails are the Tethys playbook verbatim and the engine is
   unit-tested, so the owner accepted going straight to active.
3. **Go active** — ✅ done 2026-09-10, chart 0.3.1: `demeter.mode: active`
   in `.config/lab/pomona.yaml`, released together with retiring the Tethys
   hourly task (`tethys-ph-watch` paused, dosing grant revoked). Two brains
   must never dose one tank; the foreign-dose lockout (any live
   `dose/result` Demeter did not command restarts its 60 min clock) guards
   the window. Fallback to observe-only = delete the `mode: active` line.
4. **#224 firmware follow-up** — open: first-class `dose/request` contract
   with firmware-local budgets; Demeter swaps transport only.

### Release log

| date | chart | change |
|---|---|---|
| 2026-09-10 19:08 | — | pomona PR #91 merges the controller into `develop`; image 0.1.0 built + pushed by hand |
| 2026-09-10 19:35 | 0.3.0 | Demeter deployed in shadow (mqtt chart 0.1.1 adds the broker user) |
| 2026-09-10 20:05 | 0.3.1 | `mode: active` in lab, Tethys paused, dosing dashboard row + dose annotations |
| pending | 0.4.0 | controller 0.2.0: self-learning brain (Bayesian dose response + Kalman pH; two config rails) — pomona PR `demeter-adaptive` |

First live cycle (evening of 2026-09-10): pod came up clean, waited out the
conservative boot lockout, then dosed 1 ml pH-Down at pH 8.24 — the expected
"buffer knee" dose; pH did not move within the first 10 min, as the
titration curve predicts for the first ml.

## Safety envelope (defense in depth)

1. **Engine rails** (tested): confirm ≥10 min, lockout 60 min, acid cap
   4 ml/24 h, nutrients once/24 h, A then B never together, stale/offline
   never dose, alert-only conditions can never dose, one action per cycle.
2. **Command validation:** a computed run outside (0, 10 s] is refused as a
   config error — never clamped into a wrong dose.
3. **Firmware rails:** 10 s hard cap, one channel at a time, stop at boot.
4. **Ledger conservatism:** doses recorded before the pump runs; missing
   ledger at boot = assume a fresh dose; foreign doses restart the lockout.
5. **Ops rails:** single replica + Recreate (single-writer), shadow-first,
   least-privilege broker user (cannot touch pump/light/OTA topics), no
   ingress but the metrics scrape.
6. **Human rails:** mode flips and quanta changes are gitops-reviewed;
   reagent bottles are physically finite; the smart-plug kill upstream of
   the unit stays.

## Observability

Prometheus (`demeter_*`): doses + ml per reagent, last-dose timestamps,
rolling budgets, lockout countdown, every decision by action/condition,
readings + ages, unit-online, would-dose. Scraped by kube-prometheus-stack;
dose steps are also visible in the InfluxDB pH/EC series and every decision
is a retained MQTT message. The **Demeter — dosing (card #278)** dashboard
row and dose annotations shipped with chart 0.3.1. **PrometheusRules are
still open**: the acid-cap STOP and the stale/offline no-dose states are
visible on the dashboard but do not page anyone yet.

## Explicitly out of scope

- pH-Up (excluded by #224 design — no reagent, no channel).
- Reverse pumping and ch4 (spare).
- Any pump/light/photoperiod control (firmware's, per #260).
- Top-ups / water level response (#270 replacement sensor first).
- HA involvement in the dosing path (HA observes via MQTT, nothing more).
