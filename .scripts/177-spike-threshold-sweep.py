#!/usr/bin/env python3
"""#177 spike-responder threshold analysis, optimised for CAPACITY-TARIFF savings.

Model: Belgian/Flemish capacity tariff bills the PEAK QUARTER-HOUR MEAN import.
The responder reduces that peak by (a) stopping battery charging, (b) discharging
to offset the loads the battery can actually serve (AC-out circuit).
"""
import csv, sys
from datetime import datetime, timedelta

PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/177data.csv"
HEM = "utility_room_home_energy_meter_electric_consumption_w"
BATT = "buzzbrick_ap3002532000565690_grid_input_power"
ACOUT = "buzzbrick_ap3002532000565690_alternating_current_out_power"

# ---- load ----
rows = []
with open(PATH) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or line.startswith(",result"):
            continue
        p = line.split(",")
        if len(p) < 6:
            continue
        try:
            t = datetime.strptime(p[3][:19], "%Y-%m-%dT%H:%M:%S")
            v = float(p[4])
        except (ValueError, IndexError):
            continue
        rows.append((t, v, p[5]))

series = {HEM: {}, BATT: {}, ACOUT: {}}
for t, v, e in rows:
    if e in series:
        series[e][t] = v
if not series[HEM]:
    print("NO HEM DATA"); sys.exit(1)

t0, t1 = min(series[HEM]), max(series[HEM])
grid = []
cur = t0
while cur <= t1:
    grid.append(cur); cur += timedelta(minutes=1)

def locf(d):
    out, last = [], 0.0
    for t in grid:
        if t in d: last = d[t]
        out.append(last)
    return out

hem, batt, acout = locf(series[HEM]), locf(series[BATT]), locf(series[ACOUT])
n = len(grid)
# kW
hem = [x/1000.0 for x in hem]
batt = [x/1000.0 for x in batt]
acout = [x/1000.0 for x in acout]

# --- glitch filter: a residential connection cannot draw 60 kW. Treat
# implausible readings as meter glitches and carry the previous sane value,
# otherwise a single bogus minute fabricates the whole capacity peak.
GLITCH_KW = 15.0
glitches = sum(1 for x in hem if x > GLITCH_KW)
def deglitch(sig):
    out, last = [], 0.0
    for x in sig:
        if x > GLITCH_KW:
            out.append(last)
        else:
            out.append(x); last = x
    return out
hem, batt, acout = deglitch(hem), deglitch(batt), deglitch(acout)
print(f"glitch filter: dropped {glitches} minute(s) reading > {GLITCH_KW} kW")
# corrected house draw = billed import minus the battery's own charging
house = [max(0.0, hem[i] - batt[i]) for i in range(n)]

days = (t1 - t0).total_seconds()/86400.0
print(f"window: {t0} -> {t1}  ({days:.1f} days, {n} minutes)")
print(f"billed import kW: p50={sorted(hem)[n//2]:.2f} p95={sorted(hem)[int(n*.95)]:.2f} max={max(hem):.2f}")
print(f"corrected house kW: p50={sorted(house)[n//2]:.2f} p95={sorted(house)[int(n*.95)]:.2f} max={max(house):.2f}")
print(f"battery charging kW: max={max(batt):.2f}, minutes charging>0.1 = {sum(1 for x in batt if x>0.1)}")
print(f"ac-out kW: p50={sorted(acout)[n//2]:.2f} p90={sorted(acout)[int(n*.90)]:.2f} max={max(acout):.2f}")

INVERTER = 3.84

def quarter_peaks(imp):
    """mean import per 15-min block -> sorted desc"""
    blocks = {}
    for i, t in enumerate(grid):
        key = (t - t0).total_seconds() // 900
        blocks.setdefault(key, []).append(imp[i])
    means = [sum(v)/len(v) for v in blocks.values()]
    means.sort(reverse=True)
    return means

base_q = quarter_peaks(hem)
print(f"\nBASELINE quarter-hour peaks (top5 kW): {[round(x,2) for x in base_q[:5]]}")

def simulate(trig, rel, cooldown_min=2, cap_min=None):
    """returns (events, discharge_minutes, modified_import[])"""
    state = 0  # 0 idle, 1 discharging
    cd = 0
    events = 0
    dmin = 0
    held = 0
    imp = list(hem)
    for i in range(n):
        if cd > 0: cd -= 1
        if state == 0:
            if house[i] >= trig and cd == 0:
                state = 1; events += 1; held = 0
        else:
            held += 1
            if house[i] <= rel or (cap_min and held >= cap_min):
                state = 0; cd = cooldown_min
        if state == 1:
            dmin += 1
            # responder commands DISCHARGING:
            #  - battery charging stops  -> import loses batt[i]
            #  - battery serves what it physically can of the AC-out load
            offset = min(INVERTER, acout[i])
            imp[i] = max(0.0, house[i] - offset)
    return events, dmin, imp

EUR_PER_KW_MONTH = 4.0
print("\n" + "="*104)
print(f"{'trigger':>7} {'release':>7} {'cap':>5} | {'ev/day':>7} {'disch min/day':>13} | {'peak kW':>8} {'Δpeak':>7} | {'€/mo':>6} {'€/yr':>7}")
print("="*104)

results = []
for trig in (1.5, 2.0, 2.5, 3.0):
    for rel in (0.8, 1.0, 1.5):
        if rel >= trig: continue
        for cap in (None, 15):
            ev, dm, imp = simulate(trig, rel, cap_min=cap)
            q = quarter_peaks(imp)
            peak = q[0]
            dpeak = base_q[0] - peak
            eur_m = dpeak * EUR_PER_KW_MONTH
            caps = str(cap) if cap else "-"
            print(f"{trig:>7.1f} {rel:>7.1f} {caps:>5} | {ev/days:>7.1f} {dm/days:>13.0f} | {peak:>8.2f} {dpeak:>7.2f} | {eur_m:>6.2f} {eur_m*12:>7.2f}")
            results.append((dpeak, trig, rel, cap, ev/days, dm/days, peak))

results.sort(key=lambda r: (-r[0], r[1], r[2], -1 if r[3] is None else r[3]))
print("\nBEST BY PEAK REDUCTION:")
for r in results[:5]:
    dpeak, trig, rel, cap, evd, dmd, peak = r
    print(f"  trigger={trig} release={rel} cap={cap}: Δpeak={dpeak:.2f}kW  peak {base_q[0]:.2f}->{peak:.2f}  {evd:.1f}ev/day {dmd:.0f}min/day")

# how much of the peak is battery charging?
i_peak = max(range(n), key=lambda i: hem[i])
print(f"\nAt the single highest billed minute ({grid[i_peak]}): import={hem[i_peak]:.2f}kW "
      f"house={house[i_peak]:.2f}kW battery_charging={batt[i_peak]:.2f}kW acout={acout[i_peak]:.2f}kW")

# top quarter-hours: how many coincide with charging?
blocks = {}
for i, t in enumerate(grid):
    key = (t - t0).total_seconds() // 900
    blocks.setdefault(key, {"imp": [], "batt": [], "house": []})
    blocks[key]["imp"].append(hem[i]); blocks[key]["batt"].append(batt[i]); blocks[key]["house"].append(house[i])
ranked = sorted(blocks.items(), key=lambda kv: -sum(kv[1]["imp"])/len(kv[1]["imp"]))
print("\nTOP 8 BILLED QUARTER-HOURS (what actually sets the capacity peak):")
print(f"{'when':>20} {'import':>7} {'house':>7} {'charge':>7}  charging-share")
for key, b in ranked[:8]:
    when = t0 + timedelta(seconds=key*900)
    mi = sum(b["imp"])/len(b["imp"]); mb = sum(b["batt"])/len(b["batt"]); mh = sum(b["house"])/len(b["house"])
    share = (mb/mi*100) if mi > 0 else 0
    print(f"{str(when):>20} {mi:>7.2f} {mh:>7.2f} {mb:>7.2f}  {share:>5.0f}%")
