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

## Owner runbook — onboarding the tower's brain (#291)

1. **Broker user.** The brain reuses the least-privilege **`pomona-demeter`**
   EMQX user (subscribe `pomona/#`; publish `pomona/dose/test`,
   `pomona/pump/override`, `pomona/demeter/#`). For the soak it publishes
   its own documents under `pomona/demeter-shadow/#`, so **add
   `pomona/demeter-shadow/#` to its publish allow-list** (live mnesia rule
   via the admin API, and the DR mirror in `platform/mqtt/files/acl.conf`).
   It connects with its own client id `brain-pomona-0001` (never the live
   pod's `pomona-demeter` — EMQX kicks duplicate client ids).
2. **Seal the creds for THIS namespace.** Sealed blobs are namespace + name
   scoped; the `pomona` blobs do not decrypt here:

   ```sh
   printf '%s' "$VALUE" | kubeseal --raw \
     --controller-name sealed-secrets --controller-namespace argocd \
     --namespace demeter --name demeter-brain-pomona-0001-secrets
   ```

   Paste `MQTT_USER` / `MQTT_PASS` under
   `units.pomona-0001.secret.sealedSecret.encryptedData` in
   `.config/<env>/demeter.yaml`. Until then the pod runs, idles unconnected
   and cannot dose (envFrom is optional).
3. **Shadow soak (≥ 24 h).** With `mode: shadow` the new brain publishes
   `pomona/demeter-shadow/decision` and `demeter_would_dose{unit="pomona-0001"}`
   next to the live `pomona-demeter` pod. Compare the two decision streams
   (Influx `pomona_events` for the live one, the retained shadow topic and
   the `demeter_decisions_total{unit="pomona-0001"}` counters for the new
   one) — they must agree decision for decision.
4. **Cutover — one release, never two brains on one tank:**
   - `landingzones/pomona`: `demeter.enabled: false` (the old Deployment,
     ConfigMap, Service, ServiceMonitor and policy go away; its retained
     `pomona/demeter/ledger` stays on the broker);
   - here: `units.pomona-0001.mqtt.ownPrefix: demeter` (the new brain
     inherits the live retained ledger — the acid budget, the lockout clock,
     what it learned) and, in `.config/<env>/demeter.yaml`, `mode: active`;
   - drop `pomona/demeter-shadow/#` from the ACL again.
   Bump both chart versions; Argo applies them in one sync.
5. **Dashboard.** After the cutover every `demeter_*` series carries
   `unit="pomona-0001"` and `unit_type="aeroponic_tower"`; the `Pomona —
   Hydroponics` Demeter row keeps working unchanged (queries select by
   metric name) and gains the label for a future `unit` variable. During
   the soak the row shows the live brain; the shadow brain is visible only
   under the `unit` label.

**Rollback** at any point: `units.pomona-0001.enabled: false` here (the
shadow brain vanishes; nothing it did touched the tank) or, after the
cutover, `demeter.enabled: true` back in `landingzones/pomona` with `mode:
shadow` here — the old brain reloads the same retained ledger.

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
