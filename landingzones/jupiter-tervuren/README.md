# jupiter-tervuren landing zone (SHADOW cell)

The per-site jupiter **cell** for the `tervuren` site, deployed in **SHADOW
mode** (jupiter P3.4, card #139). Deploys `jellebens/jupiter-cell:0.4.0` as a
single-replica control loop that, every cycle, computes a full dispatch plan
(prices + forecast → `packages/dispatch`) and publishes it to MQTT — but
**commands nothing**.

## The load-bearing safety property

`controller: shadow` is the hard default (chart `values.yaml` `siteConfig.controller`
and the `CELL_CONTROLLER=shadow` env). zeus remains the **sole live battery
controller** until the P4 cutover (#142 wires the live HA reads + the `live`
mode). The 0.4.0 image additionally **refuses** to run `live`, so shadow is
belt-and-braces. Do not set `live` here.

Metric isolation: the cell emits only `jupiter_cell_*` series (each with a
`site_id="tervuren"` label). It never re-emits any `zeus_*` name, so there is
**no collision** with the live `zeus_*` Prometheus series.

## What it needs to run

- **Required at startup:** `SITE_ID=tervuren` (set by the chart). Nothing else
  is strictly required for the pod to come up and serve `/healthz` + `/metrics`.
- **Required for MQTT publish (#140):** `MQTT_USER` / `MQTT_PASS` from the
  SealedSecret `jupiter-tervuren-secrets`. A missing cred makes publishing a
  best-effort no-op — the loop keeps running (MQTT is telemetry only, never the
  actuation path).
- **Optional / deferred:** `HA_TOKEN` — the live HA reads are #142; the 0.4.0
  shadow loop defaults SoC to `soc_min` and grid power to `None`, so it is **not
  needed yet**.

## Secrets

Per-site SealedSecret `jupiter-tervuren-secrets` (keys `MQTT_USER`,
`MQTT_PASS`, optional `HA_TOKEN`), injected via `envFrom` (optional). The sealed
blobs are namespace-scoped placeholders in
[`.config/lab/jupiter-tervuren.yaml`](../../.config/lab/jupiter-tervuren.yaml) —
the main session mints the EMQX cell user and runs `kubeseal`. Until then the
chart deploys cleanly with the secret absent.

## Networking

The `CiliumNetworkPolicy` is **ingress-only by default** (egress stays fully
open), matching zeus / jupiter-central / mqtt — so the cell's egress to the
in-cluster price/forecast services, the LAN EMQX broker
(`mqtt.lab.local` → `192.168.50.181:1883`) and DNS is never severed. An egress
lockdown is an opt-in, human-reviewed step (`networkPolicy.egress.enabled`,
default `false`), with the exact destinations pre-declared.

## Site config

The tervuren site-config document (a value-for-value copy of the jupiter repo
`services/cell/sites/tervuren.yaml`, #138) is rendered into the
`jupiter-tervuren-config` ConfigMap and mounted at `/config/site.yaml`. The
0.4.0 entrypoint runs from `config_from_env()` and does not yet parse this
document (the config-wiring card does); it is mounted now so that lands as a
value-only change.

## Last-good cache volume (card #146)

The cell persists the last-good **price** and **forecast** curves to disk so a
pod restart during an upstream (price-/forecast-service) outage rehydrates the
in-memory last-good cache instead of cold-starting to a safe idle
(`jupiter_shared.cache` / `jupiter_cell.clients`). It writes to the
`price.cache_path` / `forecast.cache_path` from the site-config document, which
default to a **relative** `cache/…` path — that resolves against the container
`WORKDIR` (`/app`), which is root-owned and **not writable** by the non-root
runtime uid (1000). So without a writable mount the cell logs, every cycle:

```
WARNING jupiter_shared.cache  could not persist last-good curve to
  cache/price_last_good.json: [Errno 13] Permission denied: 'cache'
WARNING jupiter_cell.clients  could not persist last-good forecast to
  cache/forecast_last_good.json: [Errno 13] Permission denied: 'cache'
```

The in-memory last-good still holds within a pod lifetime, so the fail-safe is
intact — this is hardening for cross-restart rehydration, not a live-safety fix.

**Fix (values-driven, reusable).** The `cache` block in
[`values.yaml`](values.yaml) mounts a writable **`emptyDir`** at `cache.dir`
(default `/var/cache/jupiter-cell`) and — in
[`templates/configmap.yaml`](templates/configmap.yaml) — overrides
`price.cache_path` / `forecast.cache_path` to absolute files **under that same
dir**. `cache.dir` is the single source of truth for both the mount and the
config paths, so the volume and the paths the cell writes can never drift apart.

```yaml
cache:
  enabled: true                 # false → revert to the (broken) relative path
  dir: /var/cache/jupiter-cell  # absolute, outside the root-owned WORKDIR
  priceFileName: price_last_good.json
  forecastFileName: forecast_last_good.json
```

An `emptyDir` (not a PVC) is deliberate: the cache is a warm-start optimization,
not durable state, and the `Recreate` single-writer model wants no
shared/persistent volume. The pod's `fsGroup` (`runtime.gid`, 1000) makes the
`emptyDir` group-writable by uid 1000 — no initContainer chown needed. This
pattern is chart-generic: every future per-site cell that vendors this chart
gets a writable cache the same way.

**Expected result after deploy:** the recurring `[Errno 13] Permission denied:
'cache'` warnings stop; the cell persists `price_last_good.json` /
`forecast_last_good.json` under `/var/cache/jupiter-cell` and rehydrates them on
restart (an `INFO rehydrated N last-good … points from …` line on subsequent
starts).
