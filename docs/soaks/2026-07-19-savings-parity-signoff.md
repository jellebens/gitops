# Savings-parity soak SIGN-OFF report — card #164 (jupiter vs zeus, tervuren)

- **Date:** 2026-07-19 (target date; data pulled 2026-07-20 ~10:00Z)
- **Author:** Clio (soak & observation-report agent)
- **Card:** [#164 JUPITER: savings parity cross-check SOAK + owner sign-off](https://trello.com/c/ukTOKVw8)
- **Supersedes:** [docs/soaks/2026-07-11-savings-parity-soak.md](2026-07-11-savings-parity-soak.md) (verdict then: insufficient data, 0 clean days)
- **Gates this feeds:** kiosk dashboard migration (#165) → HA sensor swap (#166) → zeus decommission (#169); also lifting the deploy freeze and #177 spike-responder activation.
- **Sources:** Prometheus (kube-prometheus-stack, ns `observability`, retention 15d — covers the whole clean run), gitops git history, `kubectl get pods`. All queries quoted in Appendix A. **Read-only throughout; this report deploys nothing.**

---

## 1. Verdict

**READY — WITH ONE NON-NEGOTIABLE CAVEAT. The savings-parity soak has passed:
5 consecutive clean independent days (07-14 → 07-18), two high-savings evenings
in tolerance, every midnight rollover survived, zero Diverged/NoData firings.
The owner may take the sign-off — but strictly as a SAVINGS-PARITY sign-off,
NOT a logic-equivalence sign-off.**

The single caveat is structural and is **the** thing to read before signing:
the shadow logic-divergence gate (`jupiter_shadow_logic_divergence`) has been
**blind for the entire life of the series** — `jupiter_shadow_inputs_source_match`
has been `0` (min = max = `0`) across the whole retained window, because zeus
sits on partial/fallback feeds while the lar runs on primary. The gate can only
fire when inputs agree; they never agreed; so its `0` is **not evidence of
anything**. `JupiterShadowLogicGateBlind` (shipped #196, commit `4acfcae`) is
firing continuously and correctly since 07-16 18:50Z. **Do not put
"logic_divergence = 0" forward as evidence, and do not read this sign-off as
proof that the lar's control logic matches zeus's.** It proves the two stacks'
**euro savings figures track each other within tolerance** — nothing more.

Every §5.2 criterion from the prior report is met. See §2–§4 for the receipts.

---

## 2. The window and its contamination map

Clean run analysed: **2026-07-13T22:00Z → 2026-07-18T22:00Z** (Brussels days
07-14 → 07-18, CEST = UTC+2; 07-19 also observed and clean, carried as a bonus
6th day). All "days" below are Europe/Brussels local. Prometheus retention 15d;
every series is well inside it.

The clean-day counter starts **07-14**, not earlier, because the two preceding
days carried mid-day control changes (verified against git commit times):

| # | When (local) | Event | Effect |
|---|---|---|---|
| C1 | 07-12 15:22 | `cycle_penalty` 0.0 → 0.005 on lar + zeus (#190, commit `3a3a885`) | mid-day control change → **07-12 contaminated** |
| C2 | 07-13 21:25 | release 0.13.0 — capacity peak-shaving + tracing v2 (#195, commit `4c8a6cf`) | evening control-logic deploy → **07-13 contaminated** |
| C3 | 07-15 22:55 | tervuren lar image 0.13.0 → 0.13.2, poll-path I/O only (#190, commit `75587c9`) | **does NOT break the clean run** (owner ruling) — see below |
| — | every 00:02 local | midnight rollover straddle | benign, self-heals in ~2 min — see §3.2 |

**Why the 07-15 lar roll (C3) does not break the run.** Owner ruling: the lar is
not party to the savings-parity recording rules. The metric corroborates it —
the savings figure `jupiter_savings_today_eur` is produced by the
**reporting-service**, which **did not restart**: it has been up since
2026-07-13T19:31Z with **0 restarts** through the entire clean run (no
accumulator reset). Only the `jupiter-cell` (lar) pod rolled, at 07-15T20:56Z,
`0` restarts since. 07-15's parity stayed comfortably in tolerance across the
roll (EOD |Δ| €0.068, max €0.108 — the run's widest, still 43% of the €0.25
band, transient, back to €0.068 within the hour).

**No deploys touched jupiter/zeus between 07-15 22:55 and 07-19** — the deploy
freeze held. The `jupiter-cell` pod age is 4d11h / 0 restarts; the whole
reporting/price/forecast stack is 07-13, 0 restarts. 07-16, 07-17, 07-18, 07-19
are clean of any mid-day deploy.

---

## 3. The numbers

### 3.1 Per-day parity ledger (Brussels days)

`jupiter_savings_parity_abs_eur` / `_signed_eur`, `site_id="tervuren"`. EOD =
instant at 21:55Z (23:55 local, 5 min before rollover). max/p95 over a **79200s
(22h) window ending 21:55Z** — this trims the opening/closing midnight straddles
that would otherwise inflate a naive `[86100s]` max (the artifact the prior
report flagged). All values EUR; tolerance band €0.25.

| Day | Source (excl. rollover) | Rollover | EOD signed (jup−zeus) | EOD \|Δ\| | max \|Δ\| (22h) | p95 \|Δ\| (22h) | jup EOD | zeus EOD | zeus banked | samples | Clean? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 07-14 (d1) | independent | survived | +0.0115 | 0.0115 | 0.0352 | 0.0294 | 0.3905 | 0.379 | 0.379 | 2640 | **YES** |
| 07-15 (d2) | independent | survived | +0.0678 | 0.0678 | 0.1077 | 0.0832 | 0.5626 | 0.4949 | 0.4949 | 2640 | **YES** † |
| 07-16 (d3) | independent | survived | −0.0415 | 0.0415 | 0.0653 | 0.0415 | 0.7688 | 0.8103 | 0.8103 | 2640 | **YES** ★ |
| 07-17 (d4) | independent | survived | +0.0087 | 0.0087 | 0.0187 | 0.0160 | 0.2598 | 0.251 | 0.251 | 2640 | **YES** |
| 07-18 (d5) | independent | survived | −0.0197 | 0.0197 | 0.0851 | 0.0660 | 1.1182 | 1.1379 | 1.1379 | 2640 | **YES** ★ |
| 07-19 (d6, bonus) | independent | survived | +0.0067 | 0.0067 | 0.0792 | 0.0623 | 1.1831 | 1.1764 | 1.1764 | 2640 | **YES** ★ |

★ high-savings evening (zeus banked > €0.50). † 07-15 max slightly elevated by
the lar roll settling (C3); still deep inside tolerance.

**Every day: source `independent`, no NoData, Diverged silent, rollover
survived, parity ≤ €0.108 max / €0.083 p95 — an order of magnitude inside the
€0.25 band.** Across the whole 5-day run: worst single sample €0.108 (07-15),
worst EOD |Δ| €0.068 (07-15), worst p95 €0.083 (07-15).

### 3.2 Midnight rollover — survives every night

Zoomed to 30s at two boundaries (07-15→16, 07-17→18); identical, healthy shape:

```
22:00:30Z  independent=1  insuf=0  gauge=<prior day total>
22:01:00Z  independent=0  insuf=1  gauge held        ← ~2-min transient
22:02:30Z  independent=0  insuf=1  gauge held
22:03:00Z  independent=1  insuf=0  gauge=0            ← reset, resumes on independent path
```

The flip to `insufficient_history` lasts a single ~2-minute scrape window at
00:01–00:02 local, then recovers to `independent` and the gauge cleanly resets
to 0 and re-accumulates. Confirmed on **all six** nights (one blip each at
~22:02Z; 6 episodes total, each < 2 min). This is the exact opposite of the
prior report's failure mode, where the source flipped at the **first** rollover
(07-07) and stayed `insufficient_history` for **68 hours**, freezing the gauge
at €0.2375. That wedge is gone; the rollover now self-heals.

### 3.3 The ">€0.50 evenings" criterion — NOW MET

zeus banked (`zeus_daily_savings_eur{date=...}`, its own EOD figure, the proxy
the §5.2 criterion uses for "a real discharge worth testing parity against"):

| Day | zeus banked | > €0.50? | parity that day (EOD \|Δ\| / max) | In tolerance? |
|---|---|---|---|---|
| 07-14 | €0.379 | no | 0.012 / 0.035 | — |
| 07-15 | €0.495 | no (€0.005 short) | 0.068 / 0.108 | — |
| **07-16** | **€0.810** | **YES** | 0.042 / 0.065 | **YES** |
| 07-17 | €0.251 | no | 0.009 / 0.019 | — |
| **07-18** | **€1.138** | **YES** | 0.020 / 0.085 | **YES** |
| **07-19** | **€1.176** | **YES** (bonus) | 0.007 / 0.079 | **YES** |

**Two high-savings evenings inside the 5-day run (07-16, 07-18), both with
parity comfortably in tolerance — criterion MET** (a third, 07-19, follows). The
prior "0/2" reading was a mid-window snapshot taken before 07-16/18/19
completed; market volatility returned. The low days (07-14, 07-15, 07-17) are
narrow-spread days, **not** a battery or parity regression — note parity was
*tightest* on the lowest-savings day (07-17, EOD €0.009). So this is **not** an
open owner decision: waiting was not required; the evenings arrived.

### 3.4 The #196 blindness — quantified, for the record

| Series / alert | Value over whole retained window (07-06 → now) |
|---|---|
| `jupiter_shadow_inputs_source_match` | min = 0, **max = 0** (never once agreed) |
| `jupiter_shadow_logic_divergence` | max = 0 — **but structurally cannot fire** (requires inputs to agree) |
| `jupiter_savings_parity_both_present` (clean run) | min = 1, max = 1 (join continuous, no NoData) |
| `JupiterShadowLogicGateBlind` | firing continuously since 07-16 18:50Z (correct) |

The savings-parity join (`both_present`) is solid the whole run. The *logic*
gate is blind. These are two different questions; only the first is answered.

### 3.5 Alert history in/around the window

`ALERTS{...,alertstate="firing"}`, 07-06 → now:

| Alert | Episodes | In clean run? |
|---|---|---|
| `JupiterReportingSavingsParityDiverged` | 07-07 21:32→22:14; 07-09 02:02→04:44; 07-09 21:02→22:14 | **none** — all pre-run (old model / the 68h wedge) |
| `JupiterReportingSavingsParityNoData` | 07-10 18:20→20:28 (CNP outage) | **none** |
| `JupiterShadowHarnessNoData` | 07-06 10:14→10:26 (harness birth) | **none** |
| `JupiterShadowLogicGateBlind` | 07-16 18:50Z → ongoing (~86h) | firing (correct — see §3.4) |

**No parity Diverged or NoData fired at any point in 07-14 → 07-19.**

---

## 4. What this sign-off CAN and CANNOT claim

**CAN claim (evidence-backed):**
- jupiter's and zeus's **euro savings-today figures track within tolerance** —
  5 clean days, worst sample €0.108, p95 ≤ €0.083, EOD |Δ| ≤ €0.068, all ≪ €0.25.
- The reporting-service computes savings on the **independent** path
  continuously, resets correctly at every midnight, and does not wedge.
- Parity holds on **high-savings evenings** (07-16, 07-18, 07-19), not just flat
  days.

**CANNOT claim (structurally unproven):**
- **Logic / dispatch equivalence between the lar and zeus.** The shadow
  logic-divergence gate never had comparable inputs (`inputs_source_match = 0`
  for the whole soak), so it has produced **zero** logic-divergence evidence.
  A quiet gate here means "blind", not "agree".
- Anything about `price_curve_etag` / `forecast_trained_at` parity (no zeus-side
  counterpart — see jupiter-shadow README).

The sign-off decision is therefore: *"savings figures are trustworthy enough to
migrate the kiosk / HA sensor onto jupiter and retire zeus's savings role"* —
which is exactly what #165/#166/#169 need. It is **not** *"the lar decides
identically to zeus."*

---

## 5. Recommendation

**READY for the SAVINGS-PARITY sign-off.** Owner may sign #164 on the strength
of §3, provided the sign-off is recorded as **savings-parity only** with the
§3.4/§4 logic caveat attached (so #196 is not silently lost downstream).

What the sign-off unblocks:
1. **#165 kiosk dashboard migration** → **#166 HA sensor swap** → **#169 zeus
   decommission** (~2026-08-06). Note: #169 ends the cross-check entirely — after
   it, even savings-parity monitoring stops, so this sign-off is effectively the
   last independent check zeus will provide.
2. **Lifting the deploy freeze** on jupiter-tervuren.
3. **#177 spike-responder activation** (observe → active), per its own review.

What remains open regardless of this sign-off:
- **Logic equivalence is still unproven (#196).** Closing it needs comparable
  inputs — either zeus back on primary feeds, or the #197 shadow-slot A/B
  approach (lar-vNext vs live) that sidesteps the zeus-feed problem. Track
  separately; do not let the savings-parity PASS imply it.

What would have changed this verdict (none occurred): a `insufficient_history`
wedge lasting more than one rollover; a Diverged or NoData firing in-window; a
reporting-service restart mid-run resetting the accumulator; or fewer than 2
high-savings evenings in tolerance.

---

## Appendix A — reproduction queries

Prometheus (`kubectl -n observability port-forward
svc/kube-prometheus-stack-prometheus 9090`), evaluated 2026-07-20 ~10:00Z.
Per-day instant queries use `eval_ts = <day>T21:55:00Z`; max/p95 use a 79200s
(22h) lookback from `eval_ts` to skip both midnight straddles.

```
# per-day (eval_ts = <day>T21:55:00Z)
jupiter_savings_parity_signed_eur
jupiter_savings_parity_abs_eur
max_over_time(jupiter_savings_parity_abs_eur[79200s])
quantile_over_time(0.95, jupiter_savings_parity_abs_eur[79200s])
count_over_time(jupiter_savings_parity_abs_eur[79200s])          # 2640/day @30s
jupiter_savings_today_eur
zeus_savings_today_eur
zeus_daily_savings_eur{date="2026-07-DD"}                        # banked per day
min_over_time(jupiter_reporting_savings_source{source="independent"}[87000s])
max_over_time(jupiter_reporting_savings_source{source="insufficient_history"}[87000s])

# rollover zoom (±window around <day>T22:00:00Z, step 30s)
jupiter_reporting_savings_source{source="independent"}          # 1 -> 0 (2min) -> 1
jupiter_reporting_savings_source{source="insufficient_history"} # 0 -> 1 (2min) -> 0
jupiter_savings_today_eur                                       # prior total -> 0 at 22:03Z

# #196 blindness (whole retained window)
min_over_time(jupiter_shadow_inputs_source_match[340h])         # 0
max_over_time(jupiter_shadow_inputs_source_match[340h])         # 0
max_over_time(jupiter_shadow_logic_divergence[340h])            # 0 (blind, not evidence)
min_over_time(jupiter_savings_parity_both_present[206h])        # 1 (no NoData in run)

# alerts (range 07-06 -> now, step 120s, episodes split on >300s gaps)
ALERTS{alertname=~"JupiterReportingSavingsParity.*|JupiterShadowLogicGateBlind|JupiterShadowHarnessNoData",alertstate="firing"}
```

Pod evidence (`kubectl get pods -o jsonpath` on startTime/restartCount):
`reporting-service-6dc689b7c6-qtkn2` start `2026-07-13T19:31:59Z`, restarts `0`;
`jupiter-cell-bff9d8b66-9dc76` start `2026-07-15T20:56:36Z`, restarts `0`.

Contamination timestamps from `git -C /home/jelle/repos/gitops log --since=2026-07-11`:
`3a3a885` 07-12 15:22 (#190 cycle_penalty), `4c8a6cf` 07-13 21:25 (0.13.0),
`75587c9` 07-15 22:55 (lar 0.13.2 I/O-only).
