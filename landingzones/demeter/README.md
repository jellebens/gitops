# demeter — one brain per hydroponic unit

**What this is.** The landing zone of Demeter's per-unit **brains**
(demeter [ADR-0007](https://github.com/jellebens/demeter/blob/develop/docs/adr/0007-demeter-tends-many-units.md),
[ADR-0010](https://github.com/jellebens/demeter/blob/develop/docs/adr/0010-demeter-is-a-few-services.md);
card #291). Every entry in `values.yaml` `units:` renders one Deployment
`demeter-brain-<unit_id>` of `jellebens/demeter-brain`: the 0.5.1 pomona
autodosing controller, scoped to one reservoir. A brain needs the MQTT
broker and nothing else. The central services (registry, robigus, fleet)
join this zone with migration slices 2, 4 and 5.

- **Source:** <https://github.com/jellebens/demeter> (private; `services/brain`).
  Design of record: `docs/architecture.md` there.
- **Namespace:** `demeter`. Argo app `demeter` (`applications/templates/demeter`),
  sync-wave 30 with the other landing zones.
- **Unit ids** are `<name>-NNNN` (demeter ADR-0009); the tower is `pomona-0001`.

```
GIGA firmware ──MQTT (user `pomona`)──> EMQX mqtt.lab.local:1883 (ns mqtt)
                                              │
     demeter-brain-pomona-0001 (ns demeter) ──┴─ subscribe pomona/# (user `pomona-demeter`)
     the tower's brain, contract v1 (#291)       publish dose/test + pump/override + demeter*/# only
```

## The two documents a brain reads

| mounted at | rendered from | holds |
|---|---|---|
| `/config/values.yaml` | `mode` (fleet ceiling), `brain.*`, `units.<id>.{role,contract,mqtt,rails}` | what gitops decides for this brain |
| `/config/config.yaml` | `units.<id>.config` | the unit's **config document**: the ADR-0002 facts (reservoir, plants, stage, targets, reagent fills, pump calibration) — from slice 2 the registry projects it from Postgres onto retained MQTT, same shape |

**`mode` is a ceiling on every unit's `role`** (`min(role, mode, profile)`):
`mode: shadow` keeps every brain deciding and publishing but never dosing.
Per-environment facts and the flip to active live in
`.config/<env>/demeter.yaml`.

## How the tower's brain got here (#291) — and the rules that stay

**Cutover 2026-09-12 (owner; shadow soak skipped — the golden replay in the
demeter repo proves bit-for-bit 0.5.1 behaviour).** In one release:
`landingzones/pomona` `demeter.enabled: false` retired the old
`pomona-demeter` Deployment (its retained `pomona/demeter/ledger` stayed on
the broker); here `units.pomona-0001.mqtt.ownPrefix: demeter` made the new
brain inherit that ledger — the acid budget, the lockout clock, what it
learned — and `.config/lab/demeter.yaml` set `mode: active`. **Never two
brains on one tank:** sync the `pomona` app (old pod gone) before the
`demeter` app when applying such a release by hand.

- **Broker user.** The brain reuses the least-privilege **`pomona-demeter`**
  EMQX user (subscribe `pomona/#`; publish `pomona/dose/test`,
  `pomona/pump/override`, `pomona/demeter/#`) with its own client id
  `brain-pomona-0001`.
- **Creds for THIS namespace.** Sealed blobs are namespace + name scoped;
  the `pomona` blobs do not decrypt here. At the cutover the Secret
  `demeter-brain-pomona-0001-secrets` was a hand-copied stopgap of
  `pomona/pomona-demeter-secrets` (the command is in
  `.config/lab/demeter.yaml`); replace it with the sealed form:

  ```sh
  printf '%s' "$VALUE" | kubeseal --raw \
    --controller-name sealed-secrets --controller-namespace argocd \
    --namespace demeter --name demeter-brain-pomona-0001-secrets
  ```

  and paste `MQTT_USER` / `MQTT_PASS` under
  `units.pomona-0001.secret.sealedSecret.encryptedData`. Without any
  Secret the pod runs, idles unconnected and cannot dose (envFrom is
  optional).
- **Soaking a future brain.** A new image goes to one unit first with
  `mode: shadow` (or a per-unit `role: shadow`) and `mqtt.ownPrefix:
  demeter-shadow` (grant `pomona/demeter-shadow/#` to the broker user for
  the duration), so its retained documents never overwrite the live ones;
  compare `demeter_would_dose{unit=…}` and the decision streams, then flip.
- **Dashboard.** Every `demeter_*` series carries `unit="pomona-0001"` and
  `unit_type="aeroponic_tower"`; the `Pomona — Hydroponics` Demeter row
  keeps working unchanged (queries select by metric name) and gains the
  label for a future `unit` variable.

**Rollback:** `units.pomona-0001.enabled: false` here (the brain vanishes,
the retained ledger stays) and `demeter.enabled: true` back in
`landingzones/pomona` — the old 0.5.1 pod reloads the same retained ledger.

## Alerts (architecture §8 R2)

`templates/prometheusrule.yaml`: `DemeterBrainDown` (no scrape 10 min,
critical), `DemeterUnitOffline` (LWT offline 15 min, critical),
`DemeterReadingsStale` (pH older than `prometheusRule.readingsStaleSeconds`,
warning), `DemeterPlantHealth` (every `demeter_alert_active{condition}` the
brain raises, warning). Routed through Alertmanager like every other zone.

## Files

```
Chart.yaml                          bump on EVERY release (owner rule)
values.yaml                         image, fleet mode, brain cadence, the units map, probes, resources
templates/
  namespace.yaml                    ns demeter
  brain-deployment.yaml             one Deployment per enabled unit (Recreate, single replica)
  brain-configmap.yaml              values.yaml + config.yaml per unit
  brain-service.yaml                metrics Service per unit
  brain-servicemonitor.yaml         one ServiceMonitor for every brain (unit labels on the series)
  brain-ciliumnetworkpolicy.yaml    ingress-only: the Prometheus scrape
  brain-sealed-secret.yaml          MQTT_USER / MQTT_PASS per unit (rendered once sealed)
  prometheusrule.yaml               the infrastructure + plant-health alerts
```

## The registry and its database (slice 2, ADR-0011, card #292)

`templates/postgres-cluster.yaml` declares the CloudNativePG **Cluster
`demeter-pg`** (2 instances, Longhorn, database `demeter`); the operator is
the platform app `cnpg` (`applications/templates/cnpg`). The operator writes
the app secret `demeter-pg-app` that `demeter-registry`
(`templates/registry-deployment.yaml`) reads -- no database password passes
through git. The registry is the only writer of the facts and the only
publisher of every unit's retained `demeter/<unit>/sys/config`, `desired`,
`demeter/sys/units` and `demeter/sys/mode`; its API (`:8080`, in-cluster,
token-protected writes) is documented in the demeter repo
(`services/registry/README.md`).

**Onboarding the tower's facts (owner):**

1. Broker: create the `registry` EMQX user (subscribe `demeter/#`; publish
   `demeter/+/sys/config`, `demeter/+/desired`, `demeter/sys/#`; deny `#`)
   and add `subscribe demeter/pomona-0001/sys/#` to `pomona-demeter` -- both
   mirrored in `platform/mqtt/files/acl.conf`. Seal `MQTT_USER` /
   `MQTT_PASS` / `REGISTRY_TOKEN` for ns `demeter` / secret
   `demeter-registry-secrets` into `.config/<env>/demeter.yaml`.
2. Import once, from the document the brain reads today:
   `kubectl get cm demeter-brain-pomona-0001 -n demeter -o jsonpath='{.data.config\.yaml}' > /tmp/pomona.yaml`
   then `kubectl cp` it into the registry pod and run
   `demeter-registry import /tmp/pomona.yaml` there (or `POST` the facts
   through the API). Check `GET /units/pomona-0001/config` equals the file.
3. Flip `units.pomona-0001.configSource: mqtt` (per env); the brain restarts,
   logs `config document adopted vN`, and the `config:` block in the values
   can go. From then on a refill is `POST /units/pomona-0001/reagents/<r>/fills`.

Backups of the database (pg_dump to the NAS, as InfluxDB does) are a
follow-up card; until then Longhorn replication is the safety net.

## Robigus — the plant-health watch (slice 4a, card #293)

`templates/robigus-deployment.yaml`: one `demeter-robigus` pod watching every
enabled unit (its `units.yaml` is rendered from the `units:` map). It raises
what a brain cannot say about itself (`brain_offline`, `node_offline`,
`readings_stale`, `no_config`, `actuator_loss` past the profile's critical
window) and mirrors the brain's alerts, on retained
`demeter/<unit>/sys/alerts` and the fleet's `demeter/sys/alerts`; the
`DemeterPlantHealth` rule now reads its gauge `robigus_alert_active`. It never
doses and never sets an actuator. Owner steps: the `robigus` broker user (ACL
mirrored in `platform/mqtt/files/acl.conf`) and its sealed creds. Home
Assistant notifies from `demeter/+/sys/alerts` (home-assitant package
`demeter_robigus.yaml`).
