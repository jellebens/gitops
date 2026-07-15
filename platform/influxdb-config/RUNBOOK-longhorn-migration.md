# RUNBOOK — Migrate the InfluxDB data volume to Longhorn (card #182)

**Status:** PREPARED, not executed. Owner-run, **release-gated maintenance
window**. Nothing in here was executed by the agent that wrote it — the
investigation below was read-only (Prometheus/`kubectl get`, no `exec`, no
scale, no PVC mutation). The live migration is a separate owner-scheduled step.

**Goal:** move the `influxdb-influxdb2` PVC off `local-path` (node-pinned to
`k3s-node03`, no restore path if that node/disk dies — the #175 failure class)
onto `longhorn` (3 synchronous replicas on 3 distinct nodes, survives one
node/disk loss). Owner override of the #176 phase-1 decision that left InfluxDB
on local-path.

> **Sequencing — do NOT run this first.** The #176 **phase-3 pilot is
> `hermes-cortana-state` (5Gi, hermes)** — small, low-stakes, its own card. That
> pilot must prove this exact backup→Retain→swap→restore runbook end-to-end
> BEFORE the InfluxDB move. InfluxDB is the big fish, and it backs the LIVE
> savings/telemetry history — it goes AFTER the pilot succeeds. Also gated on the
> **Longhorn NAS backup target** being configured (see the "still open" note
> under Post-migration).

---

## Investigation summary (read-only, 2026-07-15)

| Fact | Value | Source |
|---|---|---|
| PVC | `influxdb-influxdb2`, ns `influxdb`, `10Gi` claim, `local-path`, RWO | `kubectl get pvc` |
| Topology | **standalone Helm-managed PVC** (chart `influxdb2-2.1.2`), *not* a StatefulSet volumeClaimTemplate; STS mounts it by `claimName` | `kubectl get sts -o jsonpath` (`volumeClaimTemplates` empty) |
| Node pin | PV has hard `nodeAffinity` to `k3s-node03.local`; pod `influxdb-influxdb2-0` runs there | `kubectl get pv … nodeAffinity` |
| PV reclaim | local-path default = **`Delete`** (deleting the PVC deletes the data) | local-path provisioner |
| **Actual data on disk** | **~80 MiB** — `storage_tsm_files_disk_bytes` ≈ 67 MiB, `storage_shard_disk_size` ≈ 78 MiB | Prometheus |
| ⚠ kubelet "used" is misleading | `kubelet_volume_stats_used_bytes` reports **~24.8 GiB used / 228.8 GiB capacity** — that is **node03's whole root fs**, not the dataset (local-path volumes report the node filesystem, not the claim) | Prometheus |
| Growth | ~80 MiB over ~17 d pod-age ≈ **~5 MiB/day** ≈ ~1.7 GiB/yr; buckets `zeus` + `homeassistant` retention **infinite** → unbounded but slow (10Gi lasts ~5 yr) | derived |
| Longhorn pool | 6 nodes, **~1859 GiB max / ~1712 GiB available, 0 GiB scheduled** (nothing migrated yet) | `nodes.longhorn.io` diskStatus |
| Longhorn replica cost | 10Gi claim × 3 = **30 GiB provisioned**, but only ~240 MiB of real data across 3 replicas — **~1.7 % of the pool** | derived |
| Existing backups | nightly full `influx backup` 03:30 (14 d retain) + hourly incremental CSV export (75 m overlap window, 3 d retain) for `zeus`,`homeassistant` → `influxdb-backups` PVC on `smb` (NAS). Recent jobs `Completed`. | `platform/influxdb-config/templates/backup.yaml`, `kubectl get pods` |

### What the numbers change about the #176 objection

The #176 "do NOT migrate" rationale was *"large, write-heavy TSDB; 3× synchronous
replication of every write on 1 GbE Pis is the wrong trade."* Quantitatively that
objection is **much weaker than assumed**: the dataset is **~80 MiB** growing
**~5 MiB/day**, not large, and the write rate is low (zeus/jupiter telemetry +
HA recorder, not a high-ingest firehose). Longhorn's 3× sync-replication overhead
is proportional to write volume, so in absolute terms it is negligible here. The
owner override is well-founded; the residual concerns (below) are real but bounded
by the small volume.

### Residual storage concerns (bounded, but real)

- **iSCSI / sync-replication latency on 1 GbE.** Each write fsync now costs a
  network round-trip to 2 replica nodes instead of a local NVMe fsync. InfluxDB's
  WAL is fsync-heavy; expect higher *per-write* latency than local-path. At ~5
  MiB/day this is immaterial to throughput, but a latency-sensitive query/write
  SLO does not exist here anyway. No synthetic write benchmark was run (a write
  is outside read-only scope); the bound is the observed write volume.
- **Rebuild storms.** A node loss triggers Longhorn to rebuild the third replica.
  Longhorn is configured **capped at 2 concurrent rebuilds/node** to protect the
  LAN the battery controller rides on. A ~80 MiB volume rebuilds in seconds — a
  non-event at this size (the concern is real only for the 25Gi Prometheus volume,
  migrated last per `docs/storage.md`).
- **Pi NVMe write-amplification.** 3× replication writes each block on 3 nodes'
  NVMe. At ~5 MiB/day of application writes the amplified wear is trivial.

---

## Chosen migration path

**Path A — scale-down + `influx backup` / `influx restore` onto a fresh
`longhorn` PVC, keeping the old local-path PV `Retain`ed for rollback.**

Rationale:
- **App-consistent.** `influx backup`/`restore` is InfluxDB-aware (bolt + engine
  + WAL flushed) — no risk of copying a torn/uncompacted file set that a raw
  file copy of a hot DB carries.
- **Tiny dataset (~80 MiB)** makes backup and restore seconds-long; the window is
  dominated by pod restart + Longhorn volume create/attach, not data movement.
- **Standalone-PVC topology** (not a volumeClaimTemplate) makes the swap clean:
  delete the one PVC, let Argo re-provision it on `longhorn`, restore into it.

### Alternatives considered and rejected

- **Path B — file-level copy via a Job mounting both PVCs.** Rejected: the chart
  couples to the fixed claim name `influxdb-influxdb2` (a second PVC needs a
  different name, forcing a rename dance), *and* raw-copying a live TSDB risks
  copying an inconsistent file set. No upside over Path A at 80 MiB.
- **Path C — Longhorn-native restore from a NAS backup.** Rejected: the Longhorn
  **backup target is not yet configured** (see `platform/longhorn/README.md` and
  `docs/storage.md`), so there is no Longhorn backup to restore from. This becomes
  viable only after the NAS backup target exists.

---

## Downtime window & write-gap analysis

- **Active write gap:** from *scale STS to 0* (writes stop) until *pod healthy +
  restore complete + writes resume*. With ~80 MiB: backup/restore ≈ seconds; the
  wall clock is Argo reconcile + Longhorn volume provision/attach + pod start +
  restore. **Estimate 10–20 min active gap; schedule a 30-min window.**
- **Who writes to InfluxDB and what the gap costs:**
  - **Home Assistant** InfluxDB integration → `homeassistant` bucket. HA does
    **not** buffer; points emitted while the endpoint is down are **dropped** —
    a gap in HA-recorded sensor history for the window.
  - **jupiter reporting-service** + **zeus cross-check** → `zeus` bucket. Same:
    points during the gap are lost from the live path.
  - Partial recovery: the **hourly incremental exports** (75-min overlapping
    window) + nightly full mean savings/telemetry can be largely reconstructed;
    a short live gap is expected and acceptable for a scheduled window.
- **⚠ Battery control is NOT affected by this gap.** The LIVE controller is the
  jupiter LAR, which actuates via **HA / MQTT**, not via InfluxDB. InfluxDB is
  **telemetry + savings history only**. Taking InfluxDB down for the window does
  **not** stop battery control, does **not** touch the LAN path zeus/HA/MQTT ride
  on, and needs **no** NetworkPolicy change (the Service name/namespace
  `influxdb-influxdb2.influxdb` is unchanged across the migration). Pick a window
  outside a price/solar transition if you want the telemetry gap to land on a
  boring part of the day, but there is no control-safety deadline.

---

## Pre-flight (do BEFORE the window)

1. **The pilot passed.** Confirm the `hermes-cortana-state` phase-3 pilot ran
   this runbook shape successfully (its own card). Do not proceed otherwise.
2. **A fresh full backup is on the NAS.** Confirm the latest `influxdb-backup-*`
   pod is `Completed`, or trigger one:
   ```sh
   kubectl -n influxdb create job --from=cronjob/influxdb-backup influxdb-backup-premigrate
   kubectl -n influxdb wait --for=condition=complete job/influxdb-backup-premigrate --timeout=300s
   ```
3. **Record the current PV name** (needed for the Retain patch and rollback):
   ```sh
   PV=$(kubectl get pvc -n influxdb influxdb-influxdb2 -o jsonpath='{.spec.volumeName}')
   echo "$PV"   # e.g. pvc-0936a72a-9727-4bc5-b6b8-b03997ee34f4
   ```
4. **Prepare the StorageClass flip as a mergeable change, do NOT merge yet.** On a
   branch, in `.config/lab/influxdb.yaml`, change `storageClass: local-path` to
   `storageClass: longhorn` (uncomment the documented target). Open the PR; it
   merges to `master` *during* the window (step 6). Merging it is the deploy.

## Migration procedure (owner-run, in the window)

> `automated.selfHeal: true` is on for the `influxdb` app — pause it first, or
> Argo will fight the manual scale/PVC steps.

```sh
# 1. Pause Argo auto-sync so manual steps aren't reverted.
argocd app set influxdb --sync-policy none

# 2. Fresh full backup (belt-and-suspenders even after pre-flight step 2).
kubectl -n influxdb create job --from=cronjob/influxdb-backup influxdb-backup-window
kubectl -n influxdb wait --for=condition=complete job/influxdb-backup-window --timeout=300s

# 3. Stop writes: scale the StatefulSet to 0 (WRITE GAP STARTS HERE).
kubectl -n influxdb scale statefulset influxdb-influxdb2 --replicas=0
kubectl -n influxdb rollout status statefulset influxdb-influxdb2 --timeout=120s

# 4. Protect the old data: flip the old PV to Retain BEFORE deleting the PVC,
#    so deleting the PVC does NOT delete the local-path data (rollback anchor).
PV=$(kubectl get pvc -n influxdb influxdb-influxdb2 -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'  # -> Retain

# 5. Delete the old PVC (no consumer now that replicas=0). The Retained PV goes
#    Released but KEEPS the data on node03.
kubectl delete pvc -n influxdb influxdb-influxdb2

# 6. DEPLOY the StorageClass flip: merge the pre-flight PR to master. Then re-sync:
argocd app set influxdb --sync-policy automated --self-heal
argocd app sync influxdb
argocd app wait influxdb --sync --health --timeout 300
#    Argo now renders a FRESH PVC `influxdb-influxdb2` on `longhorn` (empty 10Gi,
#    3 replicas) and scales the STS back to 1 (chart default). Pod starts EMPTY.
kubectl get pvc -n influxdb influxdb-influxdb2 -o wide   # STORAGECLASS -> longhorn
kubectl -n influxdb rollout status statefulset influxdb-influxdb2 --timeout=300s

# 7. Restore the data into the fresh Longhorn volume from the backup on the NAS.
#    Find the newest backup dir on the influxdb-backups PVC and restore it:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c '
  latest=$(ls -1dt /backup/influxdb-* 2>/dev/null | head -1);
  echo "restoring from $latest";
  influx restore "$latest" --full \
    --host http://localhost:8086 --token "$INFLUX_TOKEN"'
#    (The backup CronJob mounts /backup from the influxdb-backups PVC; to reach it
#    from the influxdb pod, either restore from a Job that mounts influxdb-backups,
#    or copy the newest backup dir in. See "Restore mechanics" below.)
```

### Restore mechanics (pick one)

The `influxdb-influxdb2-0` pod does **not** mount the `influxdb-backups` PVC. Two
clean ways to feed it the backup:

- **Restore Job (preferred):** run a one-shot Job in ns `influxdb` from the
  `influxdb:2.7` image that mounts `influxdb-backups` at `/backup` and runs
  `influx restore /backup/<newest> --full --host
  http://influxdb-influxdb2.influxdb --token $INFLUXDB_TOKEN` (token from the
  `influxdb-auth` secret, same as the backup CronJob). This mirrors the backup
  job in reverse and needs no cross-PVC copy.
- **Ad-hoc copy:** `kubectl cp` the newest `/backup/influxdb-*` dir out of a
  short-lived pod that mounts `influxdb-backups`, then into `influxdb-influxdb2-0`,
  then `influx restore … --full`.

### Verify (before declaring done)

```sh
# Buckets present with expected retention (zeus + homeassistant, infinite):
kubectl -n influxdb exec influxdb-influxdb2-0 -- influx bucket list --org zeus

# Data is back — spot-count a live measurement in each bucket over a known window:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket:\"zeus\") |> range(start:-30d)
  |> filter(fn:(r)=>r._measurement==\"zeus_state\") |> count() |> group() |> sum()"'

# Volume really is on Longhorn with 3 replicas, Healthy:
kubectl get pvc -n influxdb influxdb-influxdb2 -o jsonpath='{.spec.storageClassName}{"\n"}'  # longhorn
kubectl get volumes.longhorn.io -n longhorn-system   # robustness=healthy, 3 replicas

# Writes resumed on the LIVE path — newest point timestamp advances:
kubectl -n influxdb exec influxdb-influxdb2-0 -- sh -c 'influx query --org zeus "
from(bucket:\"zeus\") |> range(start:-15m)
  |> filter(fn:(r)=>r._measurement==\"zeus_state\") |> last()"'
# And in Grafana: the "Battery savings today (source of truth)" panel is live again.
```

## Rollback

- **Primary (restore failed / data looks wrong):** the fresh full backup on the
  NAS is intact and the migration is idempotent. Either re-run `influx restore
  … --full` into the Longhorn volume, or revert the StorageClass PR (back to
  `local-path`, which provisions a fresh empty local-path PVC) and `influx
  restore` into that. Write gap extends but no data is lost (the backup is the
  source of truth).
- **Deep rollback (backup itself is suspect):** the **old local-path PV is
  Retain'd** and still holds the pre-migration data on node03. Re-bind it:
  ```sh
  argocd app set influxdb --sync-policy none
  kubectl -n influxdb scale statefulset influxdb-influxdb2 --replicas=0
  kubectl delete pvc -n influxdb influxdb-influxdb2            # remove the empty longhorn PVC
  kubectl patch pv "$PV" --type merge -p '{"spec":{"claimRef":null}}'  # make the old PV Available
  # Recreate a PVC that binds specifically to the old PV by volumeName + local-path,
  # then re-enable sync. (Revert the StorageClass PR to local-path first so Argo's
  # rendered PVC matches.)
  ```
  This restores the exact pre-migration state on node03.

## Post-migration

- **KEEP the NAS backup CronJobs.** Longhorn replication is redundancy, **not
  backup** — it does not protect against logical corruption, a bad restore, or a
  cluster-wide loss. `platform/influxdb-config/templates/backup.yaml` (nightly
  full + hourly incremental to the DS918) stays exactly as-is.
- **Cool-down then clean up.** Keep the Retained old local-path PV for a few days
  as the rollback anchor. After confidence: `kubectl delete pv "$PV"` and remove
  the leftover local-path directory on node03
  (`/var/lib/rancher/k3s/storage/…-influxdb-influxdb2/`).
- **Still open (blocks the *ideal* end state, not this migration):** wire the
  Longhorn volume into Longhorn's own **snapshot/backup schedule** once the DS918
  **NFS backup target** is configured (open item on #176 /
  `platform/longhorn/README.md`). Until then, disaster recovery for this volume
  remains the NAS `influx backup` path — which is why those CronJobs stay.
