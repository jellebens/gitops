# #206 — "shape battery charging so it stops stacking on house load"

**Date:** 2026-07-23 · **Site:** tervuren · **Card:** #206 (spun out of #177)
**Outcome: NO CODE CHANGE. The card's premise is disproven** — charge shaping
already exists, is wired, and is active. Card closed with the evidence below.

> Recorded deliberately as a **negative result**. The hypothesis was plausible
> enough to file, and without this write-up it will be re-filed in a few months.

---

## 1. The hypothesis (from the #177 experiment)

The #177 activation experiment found that the top 8 billed quarter-hours were
~47–56 % battery charging stacked on a modest 1.5–2.3 kW house load. The natural
conclusion was: *dispatch isn't peak-aware about its own charging — fix it
planner-side, which is cheaper than #177's reactive charge-stop (no battery wear,
no plan disruption).*

That conclusion was wrong on both counts.

## 2. Finding A — charge shaping already exists and is active

`packages/dispatch/jupiter_dispatch/capacity.py:54-60` (card #99):

```python
charge_headroom = None
if whole_home_kw:
    charge_headroom = [max(0.0, threshold - w) for w in whole_home_kw]
```

> *"the LP may plan grid charging only up to the capacity threshold minus the
> forecast whole-home import power for that slot, clamped at 0 so a slot already
> forecast at/above the threshold plans NO charging."*

It is genuinely wired end-to-end, not dead config:

- `services/lar/jupiter_lar/plan.py:187-190` passes `whole_home_kw` into
  `build_capacity_term` on every cycle.
- `plan.py:262` logs `capacity=%s` as `"on" if capacity is not None else "off"`.
  `_capacity_term()` returns `None` whenever the whole-home forecast is missing,
  so **`capacity=on` in the live log is proof the term was actually built** —
  i.e. the per-slot charge headroom is in force right now.

Live confirmation (every 15-min cycle):

```
planned status=Optimal slot0 charge=1.292kW discharge=0.000kW capacity=on
```

## 3. Finding B — the observed peaks cost €0, and the LP was right

The threshold is `max(floor_kw, running_peak_kw)`; the docstring's reasoning is
that *"the month is already committed to that level, so only exceeding it costs
money."*

Live values on tervuren:

| Input | Value |
|---|---|
| `optimizer.capacity.enabled` | `true` |
| `rate_eur_per_kw_month` | `3.3` |
| `floor_kw` | `2.5` |
| `running_peak_kw` (July) | **5.928 kW** |
| ⇒ effective threshold | **5.928 kW** |
| ⇒ charge headroom @ 2 kW house | ≈ **3.9 kW** |

So the 4.43 kW quarter-hours flagged in #177 sit **~1.5 kW below the peak July was
already committed to**. Shaving them would have saved **nothing** — the capacity
bill for July was already set at 5.93 kW. The optimizer permitting that charging
was the *economically correct* decision, not a bug.

This also corrects the #177 write-up's framing: the ~50 % charging share in the
peak quarters is real, but it is not evidence of a planner defect.

## 4. Finding C — the "capacity-peak read failed" warnings are by design

Investigating turned up this, firing every cycle:

```
WARNING capacity-peak read failed; holding in-month last-good 5.93 kW
```

Never once succeeded in the current pod. Root cause, read live from HA via the
lar's own config and token:

| Entity | State |
|---|---|
| `sensor.fluvius_meter_1sag1100121989_peak_power` | **`unavailable`** (since 13:13Z) |
| `sensor.utility_room_home_energy_meter_electric_consumption_w` | `2265.789` W ✓ |
| `sensor.ap3002532000565690_battery_level` | `90` % ✓ |

The Fluvius integration's peak register flaps `unavailable`; the other HA reads
are healthy, so this is not connectivity. **The lar is handling it exactly as
designed** — `ha_state.py` rejects `unavailable`/`unknown` states and holds the
in-month last-good rather than fabricating a value.

This is anticipated, not a defect. From `ha_state.py:109-120` (card #180):

> *"7 days = 672 consecutive misses at the 15-min cycle cadence, so it comfortably
> survives the observed multi-hour / full-day Fluvius outages."*

Safety reasoning already covered there: within a month the register is monotonic
non-decreasing, so holding a last-good can never yield a target *above* the true
peak (never under-protects); across a month boundary the cache is dropped and the
target re-baselines to the floor (over-protects) until a fresh in-month read.

The held value (5.93) currently matches HA's own last numeric value (5.928), so
present impact is **nil**. Worst case is over-protection, which is the safe
direction.

## 5. Why July's peak is 5.93 anyway

Capacity protection has not yet governed a *full* billing month:

- the lar took over actuation at the **2026-07-06** cutover,
- capacity peak shaving was wired into the lar's served path by **#191**.

June (4.97 kW) and most of the run-up to July's 5.93 kW predate full protection,
so neither is a fair test of the feature.

## 6. The one real forward item

**2026-08-01 is the first billing month with capacity protection live from day
one.** At rollover the running peak re-baselines (to the floor, or to a fresh
read), the threshold drops from 5.93 to ~2.5 kW, and the charge headroom becomes
genuinely tight — `max(0, 2.5 − house)` is well under 1 kW during a 1.5–2 kW house
load, so the LP should sharply restrict grid charging until a new peak is
established.

That is the moment to judge the feature. Worth watching in early August:

- `jupiter_reporting_capacity_peak_kw` — should drop off 5.93 at rollover.
- Whether charging visibly backs off in the first days of the month.
- Whether the new month's peak lands materially below 5.93.
- Whether the Fluvius sensor is available *at* rollover — if it is unavailable
  then, the target re-baselines to the floor (over-protect) until a fresh read,
  which is safe but will suppress charging harder than necessary.

If August's peak still lands near 5.93 **with** the threshold tight from day one,
*then* there is a genuine planner gap and this card can be reopened with real
evidence.

## 7. Conclusion

| Claim in #206 | Verdict |
|---|---|
| Charging is not peak-aware | **False** — #99 headroom is wired and active (`capacity=on`) |
| Peaks with ~50 % charging are a defect | **False** — below the month's committed peak; cost €0 |
| A planner-side fix would beat #177 | **Not demonstrated** — nothing to fix; #177 remains the reactive complement |
| (incidental) capacity-peak read is broken | **False** — Fluvius flaps; #180 handles it with a 7-day backstop |

**No change shipped to the live optimizer.** #206 closed; re-evaluate after the
August rollover.
