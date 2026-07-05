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
