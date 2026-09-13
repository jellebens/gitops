# ceres — one Vertumnus per hydroponic unit

**What this is.** The landing zone of Ceres's per-unit **Vertumnus instances**
(ceres [ADR-0007](https://github.com/jellebens/ceres/blob/develop/docs/adr/0007-ceres-tends-many-units.md),
[ADR-0010](https://github.com/jellebens/ceres/blob/develop/docs/adr/0010-ceres-is-a-few-services.md);
card #291). Every entry in `values.yaml` `units:` renders one Deployment
`ceres-vertumnus-<unit_id>` of `jellebens/ceres-vertumnus`: the 0.5.1 pomona
autodosing controller, scoped to one reservoir. A Vertumnus needs the MQTT
broker and nothing else. The central services (registry, robigus, fleet)
join this zone with migration slices 2, 4 and 5.

- **Source:** <https://github.com/jellebens/ceres> (private; `services/Vertumnus`).
  Design of record: `docs/architecture.md` there.
- **Namespace:** `ceres`. Argo app `ceres` (`applications/templates/ceres`),
  sync-wave 30 with the other landing zones.
- **Unit ids** are `<name>-NNNN` (ceres ADR-0009); the tower is `pomona-0001`.

```
GIGA firmware ──MQTT (user `pomona`)──> EMQX mqtt.lab.local:1883 (ns mqtt)
                                              │
     ceres-vertumnus-pomona-0001 (ns ceres) ──┴─ subscribe pomona/# (user `pomona-demeter`)
     the tower's Vertumnus, contract v1 (#291)       publish dose/test + pump/override + ceres*/# only
```

## The two documents a Vertumnus reads

| mounted at | rendered from | holds |
|---|---|---|
| `/config/values.yaml` | `mode` (fleet ceiling), `Vertumnus.*`, `units.<id>.{role,contract,mqtt,rails}` | what gitops decides for this Vertumnus |
| `/config/config.yaml` | `units.<id>.config` | the unit's **config document**: the ADR-0002 facts (reservoir, plants, stage, targets, reagent fills, pump calibration) — from slice 2 the registry projects it from Postgres onto retained MQTT, same shape |

**`mode` is a ceiling on every unit's `role`** (`min(role, mode, profile)`):
`mode: shadow` keeps every Vertumnus deciding and publishing but never dosing.
Per-environment facts and the flip to active live in
`.config/<env>/ceres.yaml`.

## How the tower's Vertumnus got here (#291) — and the rules that stay

**Cutover 2026-09-12 (owner; shadow soak skipped — the golden replay in the
ceres repo proves bit-for-bit 0.5.1 behaviour).** In one release:
`landingzones/pomona` `ceres.enabled: false` retired the old
`pomona-demeter` Deployment (its retained `pomona/demeter/ledger` stayed on
the broker); here `units.pomona-0001.mqtt.ownPrefix: demeter` made the new
Vertumnus inherit that ledger — the acid budget, the lockout clock, what it
learned — and `.config/lab/ceres.yaml` set `mode: active`. **Never two
Vertumnus instances on one tank:** sync the `pomona` app (old pod gone) before the
`ceres` app when applying such a release by hand.

- **Broker user.** The Vertumnus reuses the least-privilege **`pomona-demeter`**
  EMQX user (subscribe `pomona/#`; publish `pomona/dose/test`,
  `pomona/pump/override`, `pomona/demeter/#`) with its own client id
  `vertumnus-pomona-0001`.
- **Creds for THIS namespace.** Sealed blobs are namespace + name scoped;
  the `pomona` blobs do not decrypt here. At the cutover the Secret
  `ceres-vertumnus-pomona-0001-secrets` was a hand-copied stopgap of
  `pomona/pomona-demeter-secrets` (the command is in
  `.config/lab/ceres.yaml`); replace it with the sealed form:

  ```sh
  printf '%s' "$VALUE" | kubeseal --raw \
    --controller-name sealed-secrets --controller-namespace argocd \
    --namespace ceres --name ceres-vertumnus-pomona-0001-secrets
  ```

  and paste `MQTT_USER` / `MQTT_PASS` under
  `units.pomona-0001.secret.sealedSecret.encryptedData`. Without any
  Secret the pod runs, idles unconnected and cannot dose (envFrom is
  optional).
- **Soaking a future Vertumnus.** A new image goes to one unit first with
  `mode: shadow` (or a per-unit `role: shadow`) and `mqtt.ownPrefix:
  demeter-shadow` (grant `pomona/demeter-shadow/#` to the broker user for
  the duration), so its retained documents never overwrite the live ones;
  compare `ceres_would_dose{unit=…}` and the decision streams, then flip.
- **Dashboard.** Every `ceres_*` series carries `unit="pomona-0001"` and
  `unit_type="aeroponic_tower"`; the `Pomona — Hydroponics` Ceres row
  keeps working unchanged (queries select by metric name) and gains the
  label for a future `unit` variable.

**Rollback:** `units.pomona-0001.enabled: false` here (the Vertumnus vanishes,
the retained ledger stays) and `ceres.enabled: true` back in
`landingzones/pomona` — the old 0.5.1 pod reloads the same retained ledger.

## Alerts (architecture §8 R2)

`templates/prometheusrule.yaml`: `CeresVertumnusDown` (no scrape 10 min,
critical), `CeresUnitOffline` (LWT offline 15 min, critical),
`CeresReadingsStale` (pH older than `prometheusRule.readingsStaleSeconds`,
warning), `CeresPlantHealth` (every `ceres_alert_active{condition}` the
Vertumnus raises, warning). Routed through Alertmanager like every other zone.

## Files

```
Chart.yaml                          bump on EVERY release (owner rule)
values.yaml                         image, fleet mode, Vertumnus cadence, the units map, probes, resources
templates/
  namespace.yaml                    ns ceres
  vertumnus-deployment.yaml             one Deployment per enabled unit (Recreate, single replica)
  vertumnus-configmap.yaml              values.yaml + config.yaml per unit
  vertumnus-service.yaml                metrics Service per unit
  vertumnus-servicemonitor.yaml         one ServiceMonitor for every Vertumnus (unit labels on the series)
  vertumnus-ciliumnetworkpolicy.yaml    ingress-only: the Prometheus scrape
  vertumnus-sealed-secret.yaml          MQTT_USER / MQTT_PASS per unit (rendered once sealed)
  prometheusrule.yaml               the infrastructure + plant-health alerts
```

## The registry and its database (slice 2, ADR-0011, card #292)

`templates/postgres-cluster.yaml` declares the CloudNativePG **Cluster
`ceres-pg`** (2 instances, Longhorn, database `ceres`); the operator is
the platform app `cnpg` (`applications/templates/cnpg`). The operator writes
the app secret `ceres-pg-app` that `ceres-annona`
(`templates/annona-deployment.yaml`) reads -- no database password passes
through git. The registry is the only writer of the facts and the only
publisher of every unit's retained `ceres/<unit>/sys/config`, `desired`,
`ceres/sys/units` and `ceres/sys/mode`; its API (`:8080`, in-cluster,
token-protected writes) is documented in the ceres repo
(`services/registry/README.md`).

**Onboarding the tower's facts (owner):**

1. Broker: create the `annona` EMQX user (subscribe `ceres/#`; publish
   `ceres/+/sys/config`, `ceres/+/desired`, `ceres/sys/#`; deny `#`)
   and add `subscribe ceres/pomona-0001/sys/#` to `pomona-demeter` -- both
   mirrored in `platform/mqtt/files/acl.conf`. Seal `MQTT_USER` /
   `MQTT_PASS` / `ANNONA_TOKEN` for ns `ceres` / secret
   `ceres-annona-secrets` into `.config/<env>/ceres.yaml`.
2. Import once, from the document the Vertumnus reads today:
   `kubectl get cm ceres-vertumnus-pomona-0001 -n ceres -o jsonpath='{.data.config\.yaml}' > /tmp/pomona.yaml`
   then `kubectl cp` it into the registry pod and run
   `ceres-annona import /tmp/pomona.yaml` there (or `POST` the facts
   through the API). Check `GET /units/pomona-0001/config` equals the file.
3. Flip `units.pomona-0001.configSource: mqtt` (per env); the Vertumnus restarts,
   logs `config document adopted vN`, and the `config:` block in the values
   can go. From then on a refill is `POST /units/pomona-0001/reagents/<r>/fills`.

Backups of the database (pg_dump to the NAS, as InfluxDB does) are a
follow-up card; until then Longhorn replication is the safety net.

## Robigus — the plant-health watch (slice 4a, card #293)

`templates/robigus-deployment.yaml`: one `ceres-robigus` pod watching every
enabled unit (its `units.yaml` is rendered from the `units:` map). It raises
what a Vertumnus cannot say about itself (`vertumnus_offline`, `node_offline`,
`readings_stale`, `no_config`, `actuator_loss` past the profile's critical
window) and mirrors the Vertumnus's alerts, on retained
`ceres/<unit>/sys/alerts` and the fleet's `ceres/sys/alerts`; the
`CeresPlantHealth` rule now reads its gauge `robigus_alert_active`. It never
doses and never sets an actuator. Owner steps: the `robigus` broker user (ACL
mirrored in `platform/mqtt/files/acl.conf`) and its sealed creds. Home
Assistant notifies from `ceres/+/sys/alerts` (home-assitant package
`ceres_robigus.yaml`).

### Advice (slice 4b, card #294)

Robigus 0.2.0 also owns `ceres/<unit>/sys/advice`: the unit's `sys/config`
document validated against the crop windows shipped in `ceres_shared`
(`placement` — "chili wants EC 1.8–2.4, this unit runs 1.4–1.6",
`target_outside_windows`, `water_temp_target_high`, `light_short`,
`heavy_feeder_mix`), a `suggested_targets` compromise when the mix disagrees,
and the Vertumnus's hand-dose recommendations when a unit's `role` is `advise`
(Vertumnus 0.8.0: the steps become `advice`, nothing is sent). Set
`units.<id>.role: advise` for a unit whose dosers are not calibrated yet or
that can never dose (`kratky`). The registry logs the same findings on every
projection and serves them on `GET /units/{id}/validation`. HA package
`ceres_robigus.yaml` 1.1.0 shows the advice as `sensor.ceres_<id>_advice`
plus one notification. No dosing behaviour changes for the tower (role active).

## The archive and the wire change (slice 3, card #295, ADR-0008)

`templates/telegraf-deployment.yaml`: `ceres-telegraf` archives every unit's
v2 tree into the InfluxDB bucket `ceres` — `unit_tele{unit,zone,metric}`,
`unit_actuator{unit,actuator,metric}`, `unit_meta`, `unit_docs` (the Vertumnus's
decisions and ledger, Robigus's alerts and advice, the registry's config and
desired state, dose acks — verbatim JSON, forever: the training corpus) and
`ceres_sys`. `dashboards/ceres-units.json` ("Ceres — units", folder
`ceres`) reads it with a `unit` variable. Its last row, "What Vertumnus
learned" (#300), plots the Vertumnus's learned state from the `ceres_*` gauges:
Model A (k ± sd, n, knee b), the learning curve, settle/noise/rebound, the
no-response streak against the dose responses, the Model C dosing-rate
baseline and the filtered pH — the same numbers `GET /learned` on the operator
API (vertumnus 0.12.0) gives in words. The tower's pre-cutover history stays in
the `pomona` bucket.

The tower still speaks the v1 tree; the platform broker's republish bridge
(`platform/mqtt` values `rules`, README "Republish bridge") mirrors it onto
`ceres/pomona-0001/#` and back, so the archive, Robigus and a Vertumnus on
`contract: v2` see the tower before the firmware moves.

**Owner steps** (in this order):
1. EMQX: users `telegraf-ceres` (subscribe `ceres/#`), `vertumnus-pomona-0001`
   and `unit-pomona-0001` with the rules in `platform/mqtt/files/acl.conf`;
   `homeassistant` gains `publish ceres/+/actuator/+/power_w` and
   `ceres/+/actuator/+/set`.
2. InfluxDB: bucket `ceres` (org zeus, retention forever) + a bucket-scoped
   write token. Seal `MQTT_USER` / `MQTT_PASS` / `INFLUX_TOKEN` for ns ceres /
   secret `ceres-telegraf-secrets` into `.config/<env>/ceres.yaml`.
3. Flip the Vertumnus: `units.pomona-0001.contract: v2`,
   `mqtt.legacyBaseTopic: pomona`, `mqtt.clientId: vertumnus-pomona-0001` with the
   `vertumnus-pomona-0001` creds sealed (Vertumnus image ≥ 0.9.0). The Vertumnus adopts the
   retained v1 ledger once and keeps dosing through the bench channel.
4. Firmware 2.0.0 (pomona repo) over OTA in a maintenance window; Home Assistant
   packages 2.0.0 (home-assitant repo).
5. Afterwards: `platform/mqtt` `rules.enabled: false`, clear the old retained
   `pomona/#` topics, remove `legacyBaseTopic`, retire the v1 users; delete the
   pomona ingestion bridge (`landingzones/pomona` — the bucket stays).

## The operator API of a unit (Vertumnus 0.10.0, card #296)

Every `ceres-vertumnus-<unit>` pod serves a small REST API on `:9001`
(`vertumnus.apiPort`): `GET /` (the unit at a glance), `/ph`, `/ec`, `/a`,
`/b`, `/temp/water`, `/temp/air`, `/light`, `/pump`, `/doses`, `/decision`;
`POST /ph/doses|/a/doses|/b/doses {ml, rate}` (an operator dose, sized and
railed like Vertumnus' own, judged like any other — a response clears the
no-response streak), `PUT /ph/probe` (dose once despite the streak),
`PUT /pump {state}`. The network policy admits it only from the node (kubectl
port-forward); the ceres repo's `scripts/vertumnusctl.sh` wraps it. Writes
need the `VERTUMNUS_TOKEN` key in the unit's secret
(`ceres-vertumnus-<unit>-secrets`, next to MQTT_USER / MQTT_PASS); without it
the API is read-only. Seal a random token like any other value.

## Cutover in two steps — coexistence (owner decision 2026-09-13, card #295)

The first release of this zone lands **next to** the live demeter brain
(`landingzones/demeter`, ns `demeter`), not instead of it: `.config/lab/ceres.yaml`
keeps `mode: shadow` and `contract: v2` (the tower's tree through the republish
bridge), so every Vertumnus decides and publishes but none doses, and the five
secrets may still be empty (the pods retry the broker, harmless). Soak: compare
`ceres/pomona-0001/sys/decision` with `pomona/demeter/decision`. The **cutover is
one commit**: `mode: active` here and the deletion of `landingzones/demeter`,
`applications/templates/demeter/demeter-app.yaml` and `.config/lab/demeter.yaml`
(Argo prunes ns demeter, incl. its Postgres — re-import the tower document into
Annona first). Two controllers must never dose one tank.

## Tracing (card #302)

`tracing.enabled` (default on) puts `OTEL_EXPORTER_OTLP_ENDPOINT` on every Ceres
deployment — the presence of that one env var is the whole switch in
`ceres_shared.tracing` (jupiter's #179 convention). Spans go OTLP/gRPC to the
platform Jaeger (`platform/jaeger`, which lists `ceres` in `otlpNamespaces`);
browse at https://jaeger.lab.local or in Grafana Explore (datasource `jaeger`).
What to look for: `vertumnus.cycle` (one per evaluation, with the decision and the
judgement as attributes), `vertumnus.dose` → `vertumnus.dose_result` (one trace per
dose once the node echoes the `traceparent` — firmware ≥ 2.2), `vertumnus.pump_override`,
`vertumnus.api …` / `annona.api …` (server spans; a caller's `traceparent` header
stitches in), `robigus.tick`, `carmenta.tick`. Export is fail-open: a down collector
costs spans, never a cycle. `enabled: false` removes the env and the services run
exactly as before.

## Carmenta, backups and the Grafana datasource (slice 5, card #298)

`templates/carmenta-deployment.yaml`: `ceres-carmenta`, the cross-unit
learner (architecture §5.2). It reads every unit's retained `sys/ledger`,
`sys/config` and EC telemetry and publishes a widened pooled prior on
`ceres/<unit>/sys/prior` for units that have learned nothing yet (a Vertumnus
seeds its model from it at a first boot), plus the fleet's advice — feed
forecast, shopping, placement — on `ceres/sys/advice`. With one unit it pools
the tower alone and publishes no prior. Owner: the `carmenta` broker user +
`ceres-carmenta-secrets`.

`templates/annona-backup.yaml`: a nightly `pg_dump -Fc` of the Annona
database to the NAS (PVC on the `smb` StorageClass, 30 days kept), using the
operator's app secret. Restore: copy the dump into the Annona pod or any pod
with `pg_restore`, then `pg_restore --clean --if-exists -d "$uri" <dump>`; the
next Annona start re-projects every unit.

`templates/postgres-cluster.yaml`: a read-only role `grafana` managed by the
operator (`postgres.grafanaRole`), password from the sealed secret
`ceres-pg-grafana`; Annona's migration 0002 grants it SELECT on the tables
and views. `platform/observability-config` provisions the matching Grafana
datasource "Annona (PostgreSQL)" (`ceres-pg-rw.ceres:5432`, database `ceres`,
`sslmode=require`) with the same password sealed as `CERES_PG_PASSWORD` in ns
observability. Query the facts from Grafana: `select * from current_plants`.
