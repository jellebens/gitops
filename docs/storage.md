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
| `forecast-artifacts` | jupiter-central | 1Gi | **MIGRATED 2026-08-14 (#238).** Trainer/serving pods no longer node-pinned to the volume. |
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
  this page exists. Anything on local-path must be rebuildable or have an
  app-level backup (EMQX: mnesia peers; InfluxDB: daily NAS backups;
  Prometheus/Alertmanager: accepted-loss until migrated).

## Operational rules

- Longhorn deploy (waves 12/13) adds the StorageClass + control plane only;
  **capacity appears node-by-node as the owner labels**
  `node.longhorn.io/create-default-disk=true` (wired-path nodes only — the
  AiMesh wireless backhaul must never carry replica traffic).
- Pre-deploy node checklist (open-iscsi etc.):
  [`platform/longhorn/README.md`](../platform/longhorn/README.md).
- Migration protocol per PVC (phase 3): backup current data → create
  longhorn PVC → copy → verify app healthy → keep old PV `Retain`ed for a
  cool-down before cleanup. Each migration is its own card/PR.
