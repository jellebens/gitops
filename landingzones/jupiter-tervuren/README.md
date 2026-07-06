# jupiter-tervuren landing zone (LIVE)

The per-site jupiter unit for the `tervuren` site. **As of 2026-07-06 (card
#153) it is the LIVE battery controller** — zeus is demoted to a running
cross-check. Deploys `jellebens/jupiter-cell:0.5.0` as a single-replica control
loop that, every cycle, reads live battery/house state from Home Assistant,
computes a dispatch plan (prices + forecast → `packages/dispatch`), publishes it
to MQTT, and — gated by the single-controller interlock — commands the battery's
working-mode select.

> **Naming:** the per-site unit is being renamed **cell → lar** (card #154, in
> flight). Until that ships, the deployed artifacts still carry "cell": image
> `jupiter-cell`, metrics `jupiter_cell_*`, EMQX user `cell-tervuren`, namespace
> `jupiter-tervuren`. This doc uses the current (deployed) names.

## The load-bearing safety property — exactly ONE controller per battery

Enforced in **code, not procedure**, by the single-controller **interlock**
(`jupiter_cell.interlock`, cards #150/#151):

- zeus emits a **commander signal** — metric `zeus_commander{site_id}` (1 = zeus
  is commanding, 0 = demoted to a check) plus a **retained** MQTT heartbeat
  `zeus/tervuren/commander` (`{"commander":0|1,"ts":<epoch>,"site":"tervuren"}`).
- The cell actuates **only** when it reads a **fresh `commander==0`**. It
  **refuses** (safe-holds, commands nothing) on `commander==1`, a stale
  timestamp (age ≥ 2× cycle interval), or no/unparseable signal. Every
  uncertainty fails SAFE — better no controller for a few minutes than two.
- `jupiter_controllers_live{site_id}` must read **1**. `>1` is the invariant
  violated (a double-live PrometheusRule keys on it).

**zeus as the check:** with `control.enabled: false`, zeus keeps forecasting,
optimizing and reporting savings (`zeus_savings_today_*`) but **commands
nothing** and emits `commander=0`. It is the live cross-check and the instant
rollback target — its pod stays running (NOT `replicas: 0`).

## Go-live cutover runbook (card #153)

The flip is **one gitops commit** (Argo applies it; the pod `checksum/config`
annotation rolls both pods):

| File | Change |
| --- | --- |
| `landingzones/zeus/values.yaml` | `config.control.enabled: true → false` (zeus → check, `commander=0`) |
| `landingzones/jupiter-tervuren/values.yaml` | `siteConfig.controller: shadow → live` |
| `landingzones/jupiter-tervuren/values.yaml` | `siteConfig.control.enabled: false → true` |

**Prerequisites (all learned the hard way — verify before flipping):**

1. **zeus ≥ 0.8.0** deployed (emits the commander signal). Confirm
   `zeus_commander` is present and the retained `zeus/tervuren/commander` topic
   exists on the broker.
2. **cell ≥ 0.5.0** deployed (live HA reads + actuation + interlock). An older
   image `load_site_config`-raises on the `ha:`/`control:` keys.
3. **`HA_TOKEN`** sealed into `jupiter-tervuren-secrets` (live reads + actuation).
   Sanity-check its decoded length (~180 B JWT, **not** ~20 B — a truncated seal
   401s). One HA instance per site; the token is that site's HA.
4. **EMQX ACL — the #153 blocker.** The `cell-tervuren` user MUST be allowed to
   **subscribe** `zeus/tervuren/commander`, else the interlock reads UNKNOWN and
   the cell refuses forever. Its rule set (verify via the admin API):
   ```
   allow  all        jupiter/tervuren/#
   allow  subscribe  zeus/tervuren/commander      <-- required for the interlock
   deny   all        #
   ```
   (Persisted for DR by card #156; see [platform/mqtt](../../platform/mqtt/).)
5. **Timing:** cut in a quiet quarter — avoid `xx:00/:15/:30/:45 ± 2 min` (the
   ENTSO-E / cycle boundary) and a mid-charge-guard-hold quarter.

**After the merge + Argo sync:** if the cell's startup cycle happened to read the
**stale** retained `commander=1` (zeus hadn't published `0` yet at that instant),
it will safe-hold and only re-check on its next 15-min cycle. Force an immediate
re-read:

```sh
kubectl rollout restart deploy/jupiter-cell -n jupiter-tervuren
```

Its next startup cycle reads the fresh `commander=0` → interlock CLEAR → first
live command. (Card #155 makes the interlock event-driven so this restart is not
needed for future site cutovers.)

**Verification (within ~2 cycles):**

```sh
# cell metrics — controllers_live MUST be 1
kubectl exec -n jupiter-tervuren deploy/jupiter-cell -- \
  python -c 'import urllib.request;print(urllib.request.urlopen("http://localhost:8080/metrics").read().decode())' \
  | grep -E 'jupiter_controllers_live|jupiter_cell_live_actuating|jupiter_zeus_commander_value'
# expect: controllers_live 1, live_actuating 1, commander_value 0
```

- HA `select.apex300_working_mode` matches the cell's `intent0`.
- `zeus_commander 0`, zeus still writing `zeus_savings_today_*` (the check).
- `zeus_*` kiosk series continuous across the flip (no gap).

**Rollback — one revert.** Revert the cutover commit (`git revert -m 1 <merge>`)
→ zeus `control.enabled: true` (`commander=1`, reclaims the battery) + cell
`controller: shadow`. Argo rolls both pods; the interlock stands the cell down.
~2–3 min. This was exercised cleanly during the #153 cutover.

## What it needs to run

- **Required:** `SITE_ID=tervuren` (chart-set); `MQTT_USER`/`MQTT_PASS` and
  **`HA_TOKEN`** from `jupiter-tervuren-secrets`. Live actuation needs all three.
- **HA reads (#148):** SoC, whole-home grid power, house load, A/C, and the
  Fluvius capacity-peak register, read from HA REST via `HA_TOKEN`. Every read is
  fail-safe: on error it keeps last-good or a safe default and **never fabricates
  a setpoint**. The Aeotec HEM is actively poked (`zwave_js.refresh_value`,
  `run.grid_power_poll_seconds: 60`) before the grid read so the register isn't
  stale.
- **Actuation (#149):** the working-mode select (`select.apex300_working_mode`,
  options `CHARGING`/`DISCHARGING`/`PASSTHROUGH`), ported value-for-value from
  zeus's controller (guarded setpoints, `_last_option` dedup with
  first-command-explicit at handover, control-availability, charge-guard veto).
  Every command passes `control.enabled` **and** the interlock first.

## Metrics

`jupiter_cell_*` (plan, HA-read health `jupiter_cell_ha_read_ok` /
`_errors_total`), plus the actuation + interlock series: `jupiter_controllers_live`,
`jupiter_cell_live_actuating`, `jupiter_interlock_refusals`,
`jupiter_zeus_commander_value` / `_age_seconds`, `jupiter_cell_control_available`,
`jupiter_cell_actual_mode`. All carry `site_id="tervuren"` and never re-emit any
`zeus_*` name — no collision with the live `zeus_*` series.

## Known gotchas

- **`capacity_peak`** (`sensor.fluvius_meter_..._peak_power`) is intermittently
  `unavailable` in HA → the peak-shaving guard degrades (fail-safe, no bad
  command). zeus reads the same sensor and degrades identically; it self-heals
  when the sensor next reports and the cell caches the last-good register.
- **Interlock re-check cadence** is per 15-min planning cycle → a cutover may
  need the `rollout restart` above. Tracked by card #155 (make it event-driven
  off the commander subscriber).

## Networking

`CiliumNetworkPolicy` is **ingress-only by default** (egress open), matching
zeus / jupiter-central / mqtt — the cell's egress to the in-cluster
price/forecast services, the EMQX broker (`mqtt.lab.local`), **Home Assistant
(`vesta.local:8123`)** and DNS is never severed. An egress lockdown is an opt-in,
human-reviewed step (`networkPolicy.egress.enabled`, default `false`).

## Secrets

Per-site SealedSecret `jupiter-tervuren-secrets` (`MQTT_USER`, `MQTT_PASS`,
`HA_TOKEN`), injected via `envFrom` (optional). Blobs are namespace-scoped in
[`.config/lab/jupiter-tervuren.yaml`](../../.config/lab/jupiter-tervuren.yaml);
the owner mints the token and runs `kubeseal` (strict scope, `--raw`,
`--namespace jupiter-tervuren --name jupiter-tervuren-secrets`).

## Last-good cache volume (card #146)

The cell persists the last-good **price** and **forecast** curves to a writable
`emptyDir` at `cache.dir` (default `/var/cache/jupiter-cell`) so a pod restart
during an upstream outage rehydrates the in-memory last-good cache instead of
cold-starting to safe idle. `cache.dir` is the single source of truth for both
the mount and the `price.cache_path`/`forecast.cache_path` overrides (see
[`templates/configmap.yaml`](templates/configmap.yaml)), so they can't drift. An
`emptyDir` (not a PVC) is deliberate — a warm-start optimization, not durable
state, matching the `Recreate` single-writer model. `fsGroup` (`runtime.gid`
1000) makes it group-writable by the non-root uid — no initContainer chown.

```yaml
cache:
  enabled: true                 # false → revert to the (broken) relative path
  dir: /var/cache/jupiter-cell  # absolute, outside the root-owned WORKDIR
  priceFileName: price_last_good.json
  forecastFileName: forecast_last_good.json
```
