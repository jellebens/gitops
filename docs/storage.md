# Cluster storage — what lives where and why

As of card #176 (2026-07-10). The cluster is 6× Raspberry Pi 5 (arm64, k3s),
single NVMe root filesystem per node, all wired 1 GbE at the NIC. The NAS is
a Synology DS918 (`nas001.lab.local`, 192.168.50.144).

## StorageClasses

| Class | Provisioner | Durability | Use for |
|---|---|---|---|
| `local-path` (default) | rancher.io/local-path | **None — node-pinned.** Data lives in one node's filesystem; a node/disk loss loses it (#175). | Scratch, caches, anything an app can rebuild, and state with its own replication (EMQX) |
| `longhorn` (card #176) | driver.longhorn.io | 3 synchronous replicas on 3 distinct nodes; survives one node/disk loss. `reclaimPolicy: Retain`. | Irreplaceable single-instance state that must survive a node failure |
| `smb` | smb.csi.k8s.io | On the NAS (its own RAID + lifecycle). Flaky under load; NOT for hot data paths. | Off-cluster backup/export targets (influxdb backups, zeus reports) |
| `smb-cortana` | smb.csi.k8s.io | Dedicated NAS share + NAS user for Cortana backups (strict separation) | hermes/Cortana backups only |

`local-path` **stays the default**. Longhorn is opt-in per PVC until the
pilot migration (phase 3 of #176) proves it in anger.

## Current PVCs and the Longhorn migration split (sizes = claims, 2026-07-10)

### Migrate to `longhorn` (phase 3+, one PVC per card, backup first)

| PVC | NS | Size | Why |
|---|---|---|---|
| `hermes-cortana-state` | hermes | 5Gi | **Pilot.** The #175 scar: Cortana's irreplaceable state, node-pinned for 11 days. |
| `kube-prometheus-stack-grafana` | observability | 10Gi | Dashboards/users are partly in git, but plugin state/annotations aren't; cheap to protect. |
| `price-service-cache` | jupiter-central | 1Gi | Price history cache — rebuildable but a lost node during a price-API outage hurts the LIVE optimizer. |
| `forecast-artifacts` | jupiter-central | 1Gi | LAR forecast artifacts; small, valuable for the savings audit trail. |
| `alertmanager-…-db` | observability | 5Gi | Silences/notification state; tiny. |
| `prometheus-…-db` | observability | 25Gi | Debatable (rebuildable metrics, largest volume). Migrate LAST, only if rebuild traffic proves benign; losing 107d of history on a node death is the argument for. |
| `influxdb-influxdb2` | influxdb | 10Gi | **Owner override (#182).** Moved off the "do NOT migrate" list — see the note below. Runbook: [`platform/influxdb-config/RUNBOOK-longhorn-migration.md`](../platform/influxdb-config/RUNBOOK-longhorn-migration.md). Owner-scheduled, release-gated; **after** the hermes pilot. |

**On `influxdb-influxdb2` (#182 override of the #176 decision).** #176 left this
on local-path as "large, write-heavy TSDB; 3× sync replication on 1 GbE is the
wrong trade." Read-only investigation (2026-07-15) found the real dataset is
**~80 MiB, growing ~5 MiB/day** (the kubelet "used" of ~24 GiB is node03's whole
root fs — a local-path reporting artifact, not the claim). At that size the
replica cost (10Gi×3 = ~30 GiB provisioned, ~1.7 % of the Longhorn pool) and
replication/rebuild traffic are trivial, so the owner's node/disk-failure
resilience argument wins. It is a **standalone Helm-managed PVC** (not a
volumeClaimTemplate), so the swap is clean. **The manifest is gated inert**:
`.config/lab/influxdb.yaml` keeps `storageClass: local-path` with `longhorn`
documented-but-commented — merging does NOT migrate; the owner flips it only
inside the runbook's window.

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
