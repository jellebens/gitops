# RUNBOOK — InfluxDB `site_id` historical backfill (tervuren)

**Status:** PREPARED, not executed. This is a P4-tail *tail-groundwork* runbook.
Owner runs it MANUALLY — it mutates the production InfluxDB. Nothing in here was
executed by the agent that wrote it; every command below was dried read-only as
far as the write path allows (the actual `to()`/write steps were NOT run).

**Decision context:** ADR-0019 (`site_id` tenancy, D5). The fleet shares one
InfluxDB bucket split by a `site_id` tag; all tervuren history is
`site_id=tervuren`. jupiter's writer refuses to emit an untagged point; the
historical backfill of the pre-tag zeus era is explicitly a human-gated P4
runbook — this document.

---

## TL;DR of the investigation (read-only, 2026-07-06)

The reality on the live InfluxDB is **not** "one big untagged history that needs
re-tagging." It is more specific, and it changes the recommended action:

- **InfluxDB used by the cluster:** `influxdb-influxdb2-0` in namespace
  `influxdb`, Service `influxdb-influxdb2.influxdb:80`. Org `zeus`. Admin token in
  SealedSecret `influxdb/influxdb-auth` key `admin-token` (do NOT print it; the
  in-pod `influx` CLI is already authed, so you never need to handle it directly).
- **Buckets:** `zeus` (**retention: infinite**), `homeassistant` (**infinite**),
  plus `_monitoring`/`_tasks` system buckets.
- **The zeus bucket has TWO distinct populations of `zeus_*` measurements:**

  1. **A FROZEN untagged archive (22 measurements).** Every per-name live series
     (`zeus_soc_percent`, `zeus_savings_today_eur`, `zeus_energy_stored_kwh`,
     `zeus_grid_power_w`, `zeus_mode_code`, `zeus_actual_cost_today_eur`, …)
     **stopped being written at `2026-06-28T18:38:57Z`** and is entirely
     **untagged**. zeus refactored its InfluxDB writer around that date to a
     single wide `zeus_state` point (see #2), so these old per-name measurements
     are a static historical archive that will never grow again.
  2. **A LIVE, ALREADY-TAGGED set (6 measurements).** `zeus_state` (a wide
     snapshot: `soc_pct`, `energy_stored_kwh`, `predicted_savings_eur`,
     `commander`, … as fields of one point), `zeus_savings`, `zeus_daily_savings`,
     `zeus_forecast`, `zeus_forecast_frozen`, `zeus_load_history`. These are
     written **now**, all carry `site_id=tervuren`, and `zeus_forecast` is
     future-dated. The tag cutover on these began `2026-06-27..07-04`.

- **Only tag value present in `zeus`:** `tervuren`. No other site writes yet.
- **`homeassistant` bucket:** has **no `site_id` tag at all** and **no
  `zeus_*` measurements** — the savings sensor lives there as
  `entity_id="zeus_battery_savings_today"` (HA's own recorder path, keyed by
  `entity_id`, not measurement). It is fresh and untagged. See "HA bucket" below.

### What this means

- **There is no live untagged writer to worry about in the `zeus` bucket.** The
  untagged data is a *closed archive* (frozen since 2026-06-28). The live series
  are already tagged. So the backfill is a one-shot re-tag of a bounded, static
  archive — low risk, and it can never race an active writer.
- **"Let untagged points age out under retention" is NOT available** for the
  `zeus` bucket: retention is **infinite**. Untagged archive points will live
  forever unless re-tagged or explicitly deleted. (Contrast ADR-0019's
  "age out" option — that assumed a finite retention this bucket does not have.)
- Because no current dashboard filters on `site_id` (verified: 0 `site_id`
  references across all gitops dashboard JSON), **nothing breaks whether or not
  the backfill runs.** The backfill is about *future* fleet/per-site queries
  (Grafana `site_id` template var, the forecast trainer's `include_untagged`
  flag retirement), not about fixing anything today.

### Per-measurement untagged archive sizes (zeus bucket, since 2026-05-01)

| Measurement | Untagged points | Tagged points |
|---|---:|---:|
| zeus_state | 8717 | 2893 |
| zeus_savings | 3117 | 960 |
| zeus_forecast | 1608 | 364 |
| zeus_soc_percent | 1193 | 0 |
| zeus_savings_today_eur | 1193 | 0 |
| zeus_actual_cost_today_eur | 1193 | 0 |
| zeus_baseline_cost_today_eur | 1193 | 0 |
| zeus_energy_charged_today_kwh | 1193 | 0 |
| zeus_energy_discharged_today_kwh | 1193 | 0 |
| zeus_import_price_eur_per_kwh | 1193 | 0 |
| zeus_plan_cost_eur | 1193 | 0 |
| zeus_energy_stored_kwh | 1134 | 0 |
| zeus_mode_code | 1134 | 0 |
| zeus_price_position_pct | 1134 | 0 |
| zeus_actual_mode_code | 1100 | 0 |
| zeus_battery_power_w | 1100 | 0 |
| zeus_realized_load_kwh | 1094 | 92 |
| zeus_forecast_load_kwh | 1094 | 0 |
| zeus_predicted_baseline_cost_eur | 618 | 0 |
| zeus_predicted_optimized_cost_eur | 618 | 0 |
| zeus_predicted_savings_eur | 618 | 0 |
| zeus_solver_optimal | 504 | 0 |
| zeus_capacity_peak_kw | 459 | 0 |
| zeus_forecast_frozen | 320 | 181 |
| zeus_load_history | 264 | 92 |
| zeus_backup_reserve_pct | 159 | 0 |
| zeus_daily_savings | 11 | 9 |
| zeus_ac_history | 3 | 0 |

(`zeus_state` and `zeus_savings` show both because the tag cutover happened
mid-life of those two live measurements; the 22 zero-tagged rows are the frozen
archive.)

---

## Prerequisites

- `kubectl` access to the cluster (read + `exec` into the InfluxDB pod).
- The in-pod `influx` CLI is pre-authenticated (org `zeus`). All commands below
  run via `kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c '…'`.
- **Take a backup first.** A scheduled `influxdb-backup` CronJob already runs
  (namespace `influxdb`); confirm the most recent `influxdb-backup-*` /
  `influxdb-incremental-backup-*` pod is `Completed` before you start, or trigger
  one. The backfill only *adds* tagged series (it never deletes the untagged
  originals), so it is reversible by deleting the added series — but back up
  regardless.

## Investigate (read-only — safe to run anytime)

```sh
# Bucket + retention (confirm 'infinite' for zeus):
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c \
  "influx bucket list --org zeus"

# Which zeus_* measurements exist:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
import \"influxdata/influxdb/schema\"
schema.measurements(bucket: \"zeus\")"'

# Distinct site_id tag values (expect only: tervuren):
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
import \"influxdata/influxdb/schema\"
schema.tagValues(bucket: \"zeus\", tag: \"site_id\")"'

# Per-measurement UNTAGGED counts (the backfill work list):
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => not exists r.site_id)
  |> group(columns: [\"_measurement\"]) |> count()
  |> group() |> sort(columns: [\"_measurement\"])"'
```

## Backfill procedure (WRITE — owner-run, one measurement at a time)

**Model.** Line-protocol semantics: a point is uniquely identified by
`measurement + full tag set + timestamp`. Adding the `site_id=tervuren` tag makes
a **new series** (different tag set), so the tagged copy does **not** overwrite
the untagged original — both coexist until the untagged one is dropped. This is
why the safe order is *copy → verify → (later) drop untagged*, never mutate in
place.

`jupiter_shared.influx.line` is **byte-for-byte** `zeus.influx.line`, so a
re-emitted point with the same measurement/field/timestamp plus the added tag is
idempotent within its (tagged) series: re-running the backfill is safe (last
write wins on identical points).

### Step 0 — Safety rehearsal into a TEMP measurement (do this once)

Prove the copy shape on ONE measurement into a throwaway measurement first, so a
bad transform can never touch the real series. Pick a small one, e.g.
`zeus_ac_history` (3 points) or `zeus_backup_reserve_pct` (159).

```sh
# DRY: preview exactly what will be written (no write) — inspect the rows:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"zeus_backup_reserve_pct\")
  |> filter(fn: (r) => not exists r.site_id)
  |> set(key: \"site_id\", value: \"tervuren\")
  |> set(key: \"_measurement\", value: \"_backfill_tmp_zeus_backup_reserve_pct\")
  |> limit(n: 5)"'

# WRITE the temp copy (owner-run). This is the first real write:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"zeus_backup_reserve_pct\")
  |> filter(fn: (r) => not exists r.site_id)
  |> set(key: \"site_id\", value: \"tervuren\")
  |> set(key: \"_measurement\", value: \"_backfill_tmp_zeus_backup_reserve_pct\")
  |> to(bucket: \"zeus\", org: \"zeus\")"'

# VERIFY the temp copy: count matches the untagged source, tag is present:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"_backfill_tmp_zeus_backup_reserve_pct\")
  |> count() |> group() |> sum()"'
```

If the temp count equals the untagged source count and the tag is present, the
transform is proven. Delete the temp measurement before doing the real thing:

```sh
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c \
  "influx delete --org zeus --bucket zeus \
    --start 2020-01-01T00:00:00Z --stop 2030-01-01T00:00:00Z \
    --predicate '_measurement=\"_backfill_tmp_zeus_backup_reserve_pct\"'"
```

### Step 1 — Backfill each real measurement in place (same-name, added tag)

For each measurement `M` in the untagged list, re-emit its untagged points into
the **same measurement** with the `site_id` tag added. Because the tag makes a
new series, this does **not** overwrite or delete the untagged originals — it
adds a parallel `site_id=tervuren` series at the same timestamps.

```sh
M=zeus_soc_percent   # repeat per measurement from the table above

# Record the BEFORE count (untagged) for the audit:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c "influx query --org zeus '
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"$M\" and not exists r.site_id)
  |> count() |> group() |> sum()'"

# WRITE the tagged copy into the same measurement:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c "influx query --org zeus '
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"$M\" and not exists r.site_id)
  |> set(key: \"site_id\", value: \"tervuren\")
  |> to(bucket: \"zeus\", org: \"zeus\")'"

# VERIFY: the new tagged count equals the untagged BEFORE count:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c "influx query --org zeus '
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == \"$M\"
       and exists r.site_id and r.site_id == \"tervuren\")
  |> count() |> group() |> sum()'"
```

**Note on wide measurements (`zeus_state`, `zeus_savings`).** These already have
a live tagged series; only their pre-cutover points are untagged. The same
`not exists r.site_id` filter selects exactly the untagged remainder, so the
identical command works — it re-tags only the archive tail without touching the
live tagged series.

**`influx` CLI alternative.** If you prefer the CLI over a Flux `to()` task, the
equivalent is: export each measurement's untagged points to line protocol
(`influx query ... --raw` → annotated CSV, or a small script that emits line
protocol), append `,site_id=tervuren` to the tag set, and `influx write
--bucket zeus --org zeus`. The Flux `to()` path above is cleaner (no round-trip
to a file, no re-serialization risk) and is the recommended one; the CLI path is
the fallback if a `to()` task is disallowed.

### Step 2 — Verify the whole bucket

```sh
# Nothing untagged should remain (0 rows) after all measurements are done:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket: \"zeus\") |> range(start: 2026-01-01T00:00:00Z)
  |> filter(fn: (r) => not exists r.site_id)
  |> group(columns: [\"_measurement\"]) |> count()
  |> group() |> sort(columns: [\"_measurement\"])"'
```

### Step 3 — Transition queries/dashboards, THEN drop untagged

- **While backfill is partial**, any dashboard that starts filtering on
  `site_id` must use the ADR-0019 transition predicate so it sees both eras:
  `filter(fn: (r) => r.site_id == "tervuren" or not exists r.site_id)`.
  (Today **no** dashboard filters on `site_id`, so this is only relevant once the
  dashboard migration plan starts adding a `site_id` template variable.)
- **After** Step 2 shows zero untagged points and the tagged counts match the
  recorded BEFORE counts, flip any such predicate to tag-only
  (`r.site_id == "tervuren"`) and retire the forecast trainer's
  `include_untagged: true` flag (ADR-0019).
- **Optionally drop the untagged originals** to reclaim series cardinality (the
  tagged copies are now the record). This is the only destructive step and is
  entirely optional — the untagged originals are harmless if left:
  ```sh
  # OPTIONAL, per measurement, ONLY after verification. Deletes the UNTAGGED
  # series (the predicate cannot express "not exists tag", so this deletes the
  # measurement's points that have no site_id by deleting the whole measurement
  # over the archive window AFTER confirming the tagged copy exists — prefer to
  # simply LEAVE them; infinite retention means there is no storage pressure to
  # justify a delete). If you do delete, scope by measurement + a time window
  # that ENDS at the tag cutover so the live tagged series is never in range.
  echo "Prefer to LEAVE untagged archive in place; delete only with explicit intent."
  ```
  Recommendation: **do not delete.** With infinite retention there is no pressure
  to, and keeping the untagged archive is a zero-risk safety net. Retire the
  `include_untagged` flag once the tagged copies verify, and let the untagged
  originals sit as a cold archive.

## HA bucket (`homeassistant`) — savings sensor path

`home-energy-ha.json`'s "Battery savings today (zeus — source of truth)" panel
reads `entity_id="zeus_battery_savings_today"`, `_field="value"` from the
**`homeassistant`** bucket — this is HA's own InfluxDB recorder, not zeus's
writer. It is **untagged** (no `site_id`) and **fresh** (verified writing at
2026-07-06 17:30, value ~0.36).

- This path is **out of scope for the zeus-bucket backfill** and is driven by
  HA's InfluxDB integration config, not by zeus/jupiter code.
- If per-site tenancy is ever wanted in the HA bucket, it is a separate change
  in Home Assistant's recorder/influx config (add a `site_id` tag at write time),
  not a Flux backfill of the `zeus` bucket. Flag for the HA config owner
  (hestia); it is **not** part of ADR-0019's zeus-bucket scope.

## Rollback / safety

- **The backfill is additive.** It never mutates or deletes the untagged
  originals; it writes a parallel tagged series. Rollback = delete the tagged
  copies (`influx delete` scoped by `_measurement` + `site_id=tervuren` over the
  archive window), leaving the untagged archive exactly as before.
- **Temp-measurement rehearsal (Step 0)** ensures the transform is proven before
  any real series is touched. Never run a `to()` straight onto a real measurement
  without the temp rehearsal on at least one measurement first.
- **Idempotent.** Re-running Step 1 on a measurement rewrites identical
  (tagged) points — last-write-wins, no duplicates within the tagged series.
- **Take an InfluxDB backup before Step 1** (the `influxdb-backup` CronJob, or a
  manual one). The backup CronJob writing to NAS is the durable rollback of last
  resort.

## Effort estimate

~28 measurements, all bounded (max ~8.7k points, most ~1.2k). A `to()` per
measurement is sub-second. The whole backfill is minutes of wall-clock, dominated
by the operator stepping through the verify-per-measurement loop. Not time-boxed;
run it whenever convenient before the ~August zeus decommission, since retiring
the trainer's `include_untagged` flag depends on it.
