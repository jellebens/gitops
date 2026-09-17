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
GIGA firmware 2.3.x ──MQTT (user `unit-pomona-0001`)──> EMQX mqtt.lab.local:1883 (ns mqtt)
  ceres/pomona-0001/{tele,actuator,dose/result,sys}/…            │
                                                                 │
     ceres-vertumnus-pomona-0001 (ns ceres) ─────────────────────┴─ user `vertumnus-pomona-0001`
     the tower's Vertumnus, contract v2 (ADR-0008)     subscribe ceres/pomona-0001/# + ceres/sys/mode
                                                       publish dose/request, actuator/+/set, sys/ota/url,
                                                       its own sys/{role,decision,ledger} and LWT
```
(Until 2026-09-15 the tower spoke the v1 tree `pomona/…` — firmware 1.x as user `pomona`,
the Vertumnus through a v1 adapter, later through the republish bridge. That world is
retired: "The archive and the wire change" below, step 5.)

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
`ceres_sys`. Telegraf's own `internal_*` stats go to its Prometheus output
only (`namedrop` on the Influx output, #307): the bucket is the units' archive,
not the agent's.

`dashboards/` holds four boards in the Grafana folder `ceres`. Three are written by
`dashboards/generate.py` (card #307) — edit the generator and rerun it
(`python3 generate.py`; `--check` fails when the JSON is stale), never the JSON:

- `ceres-unit.json` — "Ceres — unit" (uid `ceres-units`, variable `unit`): a
  status strip (node, role, firmware running vs desired, alerts, advice, the
  plug's watts, config version), the dosing state (pH, 24 h pH-Down, last and
  pending dose, lockout, planned ml, reading age, stage), pH and EC from the
  archive with the stage's target band and the aim from `ceres_target` /
  `ceres_aim_ph`, doses and blocked doses as annotations, the mixing evidence
  (measured watts against requested / powered / mixing), pump state and reason,
  decisions per hour, bottles (remaining, days left at the learned rate), the
  alert timeline, and the "What Vertumnus learned" row.
- `ceres-fleet.json` — "Ceres — fleet": every unit side by side — Robigus's
  alerts and advice as tables, Annona's registry (SQL, datasource
  `ceres-annona`), pH/EC per unit, each unit's k against Carmenta's pool.
- `ceres-operations.json` — "Ceres — operations": firmware desired (Annona
  SQL) vs running (`ceres_firmware_*`), OTA requests, config versions, service
  liveness from `ceres/sys/status/*`, and the archive's health (newest point
  per measurement, points per hour).

The fourth is hand-written, designed one panel at a time in the ceres repo's
`grafana/` folder (see its README for the workflow) and copied here when done:

- `ceres-units-overview.json` — "Ceres — units overview" (uid `ceres-unit-use`):
  one table tile per unit — Node, Water, pH, EC and the three bottles as %
  remaining — every value on a red / amber / green background, each cell a link
  into "Ceres — unit" for that unit. A Grafana table colours a column by one
  threshold only, so the colour is decided in PromQL: one instant query per
  state and row, each adding a code offset to the value (first digit = colour,
  second = row, then thousands: `32027.2` is a hot 27.2 °C), `Reduce → series to
  rows` builds the table and regex value mappings strip the code again. Adding
  a unit is a copy of the panel with the unit id replaced in the title and in
  every `expr`. Readings use `metric="ec"` / `metric="water_temp"`, targets
  `metric="ec_ms_cm"`.

The "What Vertumnus learned" row (#300) plots the Vertumnus's learned state from the `ceres_*` gauges:
Model A (k ± sd, n, knee b), the learning curve, settle/noise/rebound, the
no-response streak against the dose responses, the Model C dosing-rate
baseline and the filtered pH — the same numbers `GET /learned` on the operator
API (vertumnus 0.12.0) gives in words. The tower's pre-cutover history stays in
the `pomona` bucket.

The tower speaks the v2 tree itself since firmware 2.3.0 went on over the air
(2026-09-15 17:01; 2.3.1 since, ceres #315). Before that the platform broker's
republish bridge (`platform/mqtt` values `rules`, README "Republish bridge")
mirrored the v1 tree onto `ceres/pomona-0001/#` and back, so the archive, Robigus
and a Vertumnus on `contract: v2` saw the tower before the firmware moved.

**Owner steps** (in this order — 1 to 4 are history, 5 is the cleanup):
1. + 2. **One script**: `bash landingzones/ceres/scripts/onboard-secrets.sh`
   (`--dry-run` first if you like). It creates or resets the broker users
   `vertumnus-pomona-0001`, `annona`, `robigus`, `carmenta`, `telegraf-ceres`,
   `unit-pomona-0001` with their `acl.conf` ACLs through the EMQX admin API, adds
   the ceres grants to `homeassistant`, ensures the InfluxDB bucket `ceres`
   (retention forever) with a bucket-scoped write token, seals every value for
   ns ceres into `.config/lab/ceres.yaml`, seals the Grafana read-role password
   into two SealedSecret manifests, saves the node's password to `.secrets/ceres/`
   (gitignored, for `firmware/pomona/secrets.h`), and opens the PR to develop.
   No password ever reaches the terminal or git. Then develop → master.
3. ✅ 2026-09-13 — the Vertumnus on `units.pomona-0001.contract: v2` with
   `mqtt.legacyBaseTopic: pomona` (`.config/lab/ceres.yaml`); it adopted the retained v1
   ledger once and doses through the bench channel while the node is on 1.3.8. Home
   Assistant reads and publishes the v2 tree already (`pomona_schedule.yaml`).
4. ✅ 2026-09-15 17:01 — **firmware 2.3.0 (pomona PR #102: the v2 wire of 2.0.0–2.2.0 plus
   the home screen) over OTA, then chart 0.12.0 (gitops #421 → #426) the same evening**;
   2.3.1 followed (ceres #315: the node caps one request at 4 ml). How it went, kept as the
   runbook for the next unit: the image is made in `~/ota-tools` (WSL): compile, `lzss.py --encode`,
   `bin2ota.py GIGA`, named `pomona-<version>.ota`. Order matters: 2.x drops
   the v1 bench topic, so between the node's reboot and the release below the Vertumnus's
   dose commands reach nothing (a dose is recorded ahead of the pump and never undone — a
   false no-response). Do it when `GET /` on the operator API shows no pending violation,
   and keep the gap to minutes:
   1. `POST http://firmware.lab.local/firmware/pomona/2.3.0` with the `.ota` as the body
      (annona 0.8.0; before that the file was copied onto the PVC by hand);
   2. `PUT /units/pomona-0001/firmware {"version":"2.3.0","url":"http://192.168.50.202/firmware/pomona/2.3.0"}`
      on Annona (see "Firmware over the air"); the Vertumnus pushes the URL, the node
      stages, reboots and reports `2.3.0` in `sys/meta`;
   3. release chart 0.12.0 (`develop → master`): the lab override without
      `legacyBaseTopic` — the Vertumnus sends ml-based `dose/request` and judges the acks
      (`ceres_dose_ack_total`).
5. **The v1 cleanup (card #295 items 8a / 8b)** — doses are acked on 2.3.1, nothing reads or
   writes `pomona/#` any more (the last v1 telemetry point in the `pomona` bucket is
   2026-09-15 15:01Z; what trickles in since is only the bridge echoing v2 commands back):
   - in git (the step-5 PR): the ACL DR mirror and `onboard-secrets.sh` without the v1 world
     (`pomona-demeter`, homeassistant's `pomona/#` grants, the Vertumnus's v1 dose channel /
     pump override / ledger read / v1 OTA topic, Robigus's `pomona/#`); `landingzones/pomona`,
     its Argo application and `.config/lab/pomona.yaml` deleted (the v1 Telegraf bridge and
     the Pomona history board go; the `pomona` bucket stays as history);
   - **still to switch, two lines in `platform/mqtt`:** `values.yaml` `rules.enabled: false`
     and `Chart.yaml` `version: 0.4.0` — that rolls the broker's StatefulSet once, so do it
     after ceres card #314 (a broker restart wiped the Vertumnus's learned model) or accept
     the relearning;
   - on the broker, by the owner (admin API, as `onboard-secrets.sh` does it): PUT the
     trimmed ACLs for `vertumnus-pomona-0001`, `robigus` and `homeassistant`; delete the
     users `pomona`, `pomona-demeter`, `pomona-ingest`; delete every retained message
     under `pomona/#`;
   - in the ceres repo: `transport/v1_pomona.py`, the v2 transition path
     (`legacy_base_topic`) and Robigus's v1 reader are deleted; this chart's
     `units.<id>.contract` default and the v1-only `mqtt.baseTopic` / `ownPrefix` /
     `legacyBaseTopic` values go with the image bump that ships it.

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

## Firmware over the air (card #304 / #315)

The `.ota` images live on one RWX claim on the NAS (`templates/firmware-claim.yaml`,
`firmware.enabled`, `storageClass: smb`) that only Annona mounts (`annona.firmware.upload`).
Annona takes an image over its API and serves it back itself (annona 0.9.0): the operator
reaches it as **http://firmware.lab.local/firmware/…** through the shared gateway (route in
`.config/lab/gateway.yaml`, A record in `coredns-lab.yaml`), the **nodes** fetch it from the
Annona service's own LAN address, `annona.lan` = **http://192.168.50.202/firmware/<type>/<version>**
(a pinned Cilium LB-IPAM address, plain http). Not the gateway: the GIGA resolves no lab
hostname and its OTA client speaks HTTP/1.0, which Envoy answers with 426 — the reason the
nginx of chart 0.11.0 – 0.14.x is gone (0.15.0). A rollout:

1. Build the image in the pomona repo (`firmware/tools/lzss_ota.py`) and
   `curl -X POST -H "Authorization: Bearer $ANNONA_TOKEN" --data-binary @pomona-<version>.ota \
      http://firmware.lab.local/firmware/pomona/<version>` — checked against the OTA header,
   409 if that version is already served; the answer carries the node-facing URL.
2. `curl -X PUT -H "Authorization: Bearer $ANNONA_TOKEN" http://ceres-annona:8080/units/pomona-0001/firmware \
      -d '{"version":"2.3.1","url":"http://192.168.50.202/firmware/pomona/2.3.1"}'`
3. The unit's Vertumnus (active role, node online, tank settled) publishes the
   URL to the node's OTA topic once per version per hour; the node stages,
   reboots and reports the new `fw_version` in `sys/meta`.
   `ceres_firmware_desired_match` goes 0 → 1; `vertumnusctl.sh pomona-0001 firmware`
   shows running vs desired and the node's last result. `vertumnusctl.sh
   pomona-0001 ota <url>` is the manual push through the same rails.
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

Since 2026-09-14 (ceres ADR-0013; vertumnus ≥ 0.16.0, annona ≥ 0.5.0, robigus
≥ 0.5.0, carmenta ≥ 0.3.0) the trace crosses the broker: every JSON document a
service publishes carries the `traceparent` of the span that wrote it, a reader's
consumer span (`vertumnus.message`, `robigus.message`, `carmenta.message`) is a
child of the sender's when the broker delivers the document live and only links
to it for a retained replay — so one `vertumnus.cycle` holds the decision, Robigus
reading it and, through Home Assistant's ack (`…/sys/alerts/ack`, `…/sys/advice/ack`,
`ceres/sys/alerts/ack`; HA package `ceres_robigus.yaml` ≥ 1.3.0, the notification's
title + message since 1.4.0), `robigus.notified`. The `homeassistant` broker user
publishes the three ack topics (mqtt chart 0.3.2 ACL mirror; live rule applied
2026-09-14). Every consumer span carries the message body as `mqtt.payload` and
every publish is an `mqtt.publish` event (vertumnus ≥ 0.17.0, robigus ≥ 0.6.0,
carmenta ≥ 0.4.0, annona ≥ 0.6.0); `CERES_TRACE_PAYLOAD_CHARS=0` on a deployment
turns the body off. Known gap: after a restart a Vertumnus decides `none` for
`confirm_minutes` and publishes no decision (ceres Trello #310).

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
