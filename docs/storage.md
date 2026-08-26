# Cluster storage — what lives where and why

As of card #176 (2026-07-10). The cluster is 6× Raspberry Pi 5 (arm64, k3s),
single NVMe root filesystem per node, all wired 1 GbE at the NIC. The NAS is
a Synology DS918 (`nas001.lab.local`, 192.168.50.144).

## StorageClasses

| Class | Provisioner | Durability | Use for |
|---|---|---|---|
| `local-path` | rancher.io/local-path | **None — node-pinned.** Data lives in one node's filesystem; a node/disk loss loses it (#175). | Scratch, caches, anything an app can rebuild — and only by explicit `storageClassName` (no longer the default) |
| `longhorn` (**default** since #236) | driver.longhorn.io | 3 synchronous replicas on 3 distinct nodes; survives one node/disk loss. `reclaimPolicy: Retain`. | Irreplaceable single-instance state that must survive a node failure; the default for anything that doesn't pick a class |
| `smb` | smb.csi.k8s.io | On the NAS (its own RAID + lifecycle). Flaky under load; NOT for hot data paths. | Off-cluster backup/export targets (influxdb backups, zeus reports) |
| `smb-cortana` | smb.csi.k8s.io | Dedicated NAS share + NAS user for Cortana backups (strict separation) | hermes/Cortana backups only |

`longhorn` **is the default** since #236 (2026-08-14, owner call in the
#235–#238 migration series). The flip is two-sided — chart value
(`persistence.defaultClass: true`) plus a manual annotate on the k3s-bundled
`local-path` SC; k3s re-asserts local-path's default annotation on restart,
in which case Kubernetes still binds to the newest default (longhorn) — see
the note in [`platform/longhorn/README.md`](../platform/longhorn/README.md).

## Current PVCs and the Longhorn migration split (sizes = claims, 2026-07-10)

### Migrate to `longhorn` (phase 3+, one PVC per card, backup first)

| PVC | NS | Size | Why |
|---|---|---|---|
| `hermes-cortana-state` | hermes | 5Gi | **MIGRATED 2026-08-14 (#238).** The #175 scar (Cortana's irreplaceable state) — was the pilot candidate; landed in the same series wave as the rest. State copied cold; old PV Retain'd. |
| `kube-prometheus-stack-grafana` | observability | 10Gi | **MIGRATED 2026-08-14 (#237).** Plugin state/annotations copied from the old local-path PV (Retain'd as rollback anchor). |
| `price-service-cache` | jupiter-central | 1Gi | **MIGRATED 2026-08-14 (#238).** A lost node during a price-API outage would have hurt the LIVE optimizer; node pin gone. |
| `forecast-artifacts` | jupiter-central | 1Gi | **MIGRATED 2026-08-14 (#238).** Artifacts survive a node loss. ⚠ #238 also claimed the trainer/serving pods were no longer node-pinned — wrong, the claim is RWO; it broke every bake for 5 days until #240 re-pinned them with `podAffinity`. See "RWO is a per-node lock" below. |
| `jaeger-badger` | jaeger | 5Gi | **MIGRATED 2026-08-14 (#238).** Trace history (badger) copied cold; POSIX/block semantics preserved on longhorn (ext4-on-iSCSI). |
| `alertmanager-…-db` | observability | 5Gi | **MIGRATED 2026-08-14 (#237).** Old volume was empty (no active silences) — fresh longhorn volume, no copy. |
| `prometheus-…-db` | observability | 25Gi | **MIGRATED 2026-08-14 (#237).** 11.9G of history (15d retention) copied cold to longhorn; old PV Retain'd. The "migrate LAST" caveat was honored within the wave; rebuild traffic bounded by the 2-concurrent-rebuilds/node cap. |
| `influxdb-influxdb2` | influxdb | 10Gi | **MIGRATED 2026-08-14 (#235).** Runbook: [`platform/influxdb-config/RUNBOOK-longhorn-migration.md`](../platform/influxdb-config/RUNBOOK-longhorn-migration.md) (#182), executed as part of the #235–#238 series. Owner ordered InfluxDB first, ahead of the hermes pilot the runbook originally sequenced. Old local-path PV Retain'd on node03 as rollback anchor (cool-down, then clean up). |

**On `influxdb-influxdb2` (#182 override of the #176 decision).** #176 left this
on local-path as "large, write-heavy TSDB; 3× sync replication on 1 GbE is the
wrong trade." Read-only investigation (2026-07-15) found the real dataset is
**~80 MiB, growing ~5 MiB/day** (the kubelet "used" of ~24 GiB is node03's whole
root fs — a local-path reporting artifact, not the claim). At that size the
replica cost (10Gi×3 = ~30 GiB provisioned, ~1.7 % of the Longhorn pool) and
replication/rebuild traffic are trivial, so the owner's node/disk-failure
resilience argument wins. It is a **standalone Helm-managed PVC** (not a
volumeClaimTemplate), so the swap is clean. Executed 2026-08-14 in the #235
window: `.config/lab/influxdb.yaml` now says `storageClass: longhorn`; the NAS
`influx backup` CronJobs stay (replication is not backup).

> **Sequencing.** The `hermes-cortana-state` phase-3 pilot (5Gi, small,
> low-stakes) proves the backup→Retain→swap→restore runbook FIRST. InfluxDB is
> the **big fish after** — it backs LIVE savings/telemetry history and is also
> gated on the Longhorn NAS backup target existing. Do not run #182 before the
> pilot succeeds.

### Do NOT migrate

| PVC | NS | Size | Why not |
|---|---|---|---|
| `data-mqtt-{0,1,2}` | mqtt | 3×1Gi | EMQX replicates its own state (mnesia, 3 nodes). Longhorn under it = redundancy² and rebuild noise for nothing. |
| `influxdb-backups` | influxdb | 10Gi | Already ON the NAS (`smb`) — that's the off-cluster copy. |
| `zeus-reports` | zeus | 1Gi | Already on the NAS (`smb`), deliberately off-cluster. |
| `hermes-backup` | hermes | 10Gi | Already on the NAS (`smb-cortana`) — it's the backup of the state PVC. |

## Restore paths

- **Longhorn volume, node lost**: nothing to do — remaining replicas serve;
  Longhorn rebuilds the third replica automatically (capped at 2 concurrent
  rebuilds/node to protect the LAN the battery controller rides on).
- **Longhorn volume faulted (all replicas lost)**: restore from the Longhorn
  backup target on the NAS (UI → Backup → Restore → repoint PVC). ⚠ The
  backup target is NOT yet configured — see the decision section in
  [`platform/longhorn/README.md`](../platform/longhorn/README.md); volumes
  holding irreplaceable state must not migrate before it works.
- **NAS-backed PVCs (`smb*`)**: data lives on the DS918; restore = NAS-side
  (RAID/versioning/Hyper Backup). In-cluster PV/PVC objects are `Retain` and
  re-bindable.
- **`local-path` PVCs**: no restore path — that's the #175 lesson and why
  this page exists. Since the #235–#238 series only the `data-mqtt-{0,1,2}`
  volumes remain on local-path (EMQX replicates its own state across the 3
  brokers). The old local-path PVs of every migrated volume are **Retain'd
  as rollback anchors** — delete them (PV + node directory) only after the
  cool-down.

## Operational rules

- Longhorn deploy (waves 12/13) adds the StorageClass + control plane only;
  **capacity appears node-by-node as the owner labels**
  `node.longhorn.io/create-default-disk=true` (wired-path nodes only — the
  AiMesh wireless backhaul must never carry replica traffic).
- Pre-deploy node checklist (open-iscsi etc.):
  [`platform/longhorn/README.md`](../platform/longhorn/README.md).
- Migration protocol per PVC (proven in the #235–#238 series): backup current
  data → create temp longhorn PVC → scale consumer to 0 → copy (Job pinned to
  the old PV's node) → `Retain` the old PV → delete old + temp PVCs → clear
  the longhorn PV's `claimRef` uid and pre-bind it to the final claim name →
  merge the release → let Argo create the chart's PVC (binder binds it) →
  verify. Each migration is its own card/PR.
- **PVC-swap lessons (#235–#238, 2026-08-14):**
  1. **Pause `bootstrap` FIRST**, verify it stuck, then pause the child apps —
     bootstrap's selfHeal restores children's sync policies and Argo will
     re-provision the PVC mid-window (bit #235: ~3 min of writes discarded).
  2. **Never hand-create the final PVC with `volumeName`** — Argo
     ServerSideApply fights the pinned field ("spec is immutable"). Pre-bind
     on the **PV side** (`claimRef` with name+namespace, uid cleared) and let
     Argo create the chart's PVC.
  3. **Hard-refresh apps before unpausing** (`argocd.argoproj.io/refresh:
     hard`) — an app unpaused seconds after a release merge can sync a stale
     cached revision and create the PVC with the OLD storage class (bit #238;
     claimRef pre-binding still binds across a class mismatch, hiding it).
  4. Completed Job/CronJob pods pin PVCs (`pvc-protection`) — delete them
     before deleting a PVC or the delete hangs.

## RWO is a per-node lock — check the consumers before leaving local-path

**Moving a PVC from `local-path` to `longhorn` does not free its pods to
schedule anywhere.** The access mode does that, and every volume in the
#235–#238 series stayed `ReadWriteOnce`. RWO means *one node at a time*:
several pods on the **same** node may share the volume, a pod on any **other**
node cannot bind it at all and fails with `Multi-Attach error`.

What changes with the class is only *who enforces the co-location*:

| | `local-path` | `longhorn` |
|---|---|---|
| Binding mode | `WaitForFirstConsumer` | `Immediate` |
| Node choice | PV is created on the first consumer's node and **carries node affinity** | volume attaches wherever the first consumer happens to land |
| Later pods | scheduler honours the PV's node affinity → co-location for free | scheduler is unconstrained → **any other node fails to bind** |

So `local-path` silently satisfies the writer/reader pattern (one long-lived
pod holding the volume plus a periodic Job writing to it), and `longhorn`
silently breaks it. #240 is the worked example: the `forecast-artifacts`
migration in #238 dropped the implicit pin, and every `forecast-train` run for
the next five days died on `Multi-Attach` → `DeadlineExceeded` while the
serving pod's `/healthz` stayed green and the LIVE optimizer planned on
increasingly stale models.

**Before migrating a PVC off `local-path`, list every pod that mounts it.**
More than one consumer, and the claim is RWO? Then either:

- pin the extra consumers to the holder's node with a
  `requiredDuringSchedulingIgnoredDuringExecution` **`podAffinity`** on the
  holding pod's labels, `topologyKey: kubernetes.io/hostname` — what
  `landingzones/jupiter-central` does via `forecast.trainer.coLocateWithServer`;
  or
- move the claim to a real multi-node access mode (RWX via `smb`, or Longhorn
  RWX) — worth it only when the consumers genuinely need different nodes; a
  Longhorn RWX volume adds a share-manager NFS pod as a new SPOF, which is a
  poor trade for data the app can regenerate.

**Note the failure is silent at the pod level by construction.** The reader
keeps serving its last-written data and stays Ready; only the writer fails.
Any such pair needs a *staleness* alert on the data itself, not just liveness
on the pods.

In #240 those alerts did their job on time — `JupiterForecastTrainingFailing`
within 15 min of the first failed Job (2026-08-14 22:47) and
`JupiterForecastArtifactStale` once the age crossed 24 h (2026-08-16). Neither
was acted on for five days, and the migration series that caused it was
already closed. **A PVC migration is not done when Argo goes green** — check
the alerts of every workload that touches the volume for at least one full
period of the slowest consumer (here: one 6 h CronJob cycle).
