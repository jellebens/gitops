# Longhorn — distributed storage on the unused k3s NVMe space (card #176)

Replicated block storage across the 6 Raspberry Pi 5 k3s nodes, so
node-pinned state survives a node/disk failure. Motivated by #175: Cortana's
state sat on a single node-pinned `local-path` PVC, unprotected for 11 days.
Longhorn was chosen over Rook-Ceph/Mayastor as right-sized for 6× arm64
(officially supported on arm64 since Longhorn 1.4).

Two Argo apps (same split as `csi-driver-smb` / `csi-driver-smb-config`):

| App | Source | Wave | Contents |
|---|---|---|---|
| `longhorn` | upstream chart `longhorn` **1.11.3** from `charts.longhorn.io`, values in [`.config/lab/longhorn.yaml`](../../.config/lab/longhorn.yaml) | 12 | Longhorn itself, ns `longhorn-system`, upstream ServiceMonitor |
| `longhorn-config` | this chart (`platform/longhorn`) | 13 | CNP, PrometheusRule, Grafana dashboard, sealed backup-creds placeholder |

**Deploying this is deliberately inert:** it adds the `longhorn`
StorageClass and the control plane, but **zero storage capacity exists until
the owner labels nodes** (`createDefaultDiskLabeledNodes: true`). No data
moves automatically; migrations are per-PVC cards (#235–#238 series).

**Default StorageClass: `longhorn` since #236 (2026-08-14).** The flip is
two-sided: `persistence.defaultClass: true` here, plus a manual
`kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=false --overwrite`
(local-path is a k3s-bundled addon object, not in git). ⚠ k3s re-asserts
local-path's default annotation on k3s restart/upgrade; if both SCs claim
default, Kubernetes binds new PVCs to the **newest** default SC — longhorn —
so behaviour stays correct, but re-run the annotate command after k3s
maintenance so `kubectl get sc` shows a single `(default)`.

## Phase-1 findings (2026-07-10, read-only: node_exporter + kubectl)

### Per-node disk (single ext4 root on NVMe, `/dev/nvme0n1p2`)

| Node | IP | NVMe size | Free (2026-07-10) | Harvestable at 70% cap* |
|---|---|---|---|---|
| k3s-master01 | .151 | 234 GiB | 211 GiB | ~164 GiB |
| k3s-node01 | .152 | 234 GiB | 211 GiB | ~164 GiB |
| k3s-node02 | .153 | 234 GiB | 205 GiB | ~164 GiB |
| k3s-node03 | .154 | 229 GiB | 200 GiB | ~160 GiB |
| k3s-node04 | .155 | 458 GiB | 408 GiB | ~321 GiB |
| k3s-node05 | .156 | 469 GiB | 413 GiB | ~328 GiB |

\* `storageReservedPercentageForDefaultDisk: 30` keeps 30% of each disk for
the OS/k3s/images/local-path; `storageMinimalAvailablePercentage: 25` stops
replica scheduling below 25% free. Effective raw pool ≈ 1.3 TiB → ≈ 430 GiB
usable at 3 replicas. The current *migratable* PVC set is ~47 Gi of claims —
capacity is not a constraint.

### Wired vs wireless (the make-or-break gate)

Interface evidence from node_exporter (NOT ping RTT, which is unreliable):

- Every node has exactly one non-virtual interface up: `eth0`,
  `operstate=up`, `duplex=full`, `node_network_speed_bytes` = 125 MB/s
  (= 1 GbE) on all six.
- Zero `node_wifi_*` series exist anywhere; no `wlan*`/`wlp*` device is up.

**Verdict: all 6 nodes are wired 1 GbE at the NIC → the 3-replica default is
defensible.** Caveat the NIC cannot see: the path *between* switch/mesh
units. If any switch the Pis hang off uplinks over the AiMesh **wireless**
backhaul, synchronous replication would ride that fragile hop. Node tagging
is the control: disks are created **only** on nodes labeled by the owner
(below), so keep any node whose upstream path is wireless unlabeled.

### Prereqs — pre-deploy checklist (owner, per node)

These are **not verifiable read-only from the cluster** (no SSH/exec).

**The package/module/service items are AUTOMATED in the homelab ansible repo**
(`jellebens/homelab`, `roles/k3s/tasks/install-storage-prereqs.yml`, commit
`ae5a132`) — one targeted run covers all 6 nodes and asserts the exact
longhorn-manager precheck (`iscsiadm --version`):

```bash
cd ~/repos/homelab
ansible-navigator run playbooks/deploy_k3s.yml \
  -i inventories/shared -i inventories/lab/k3s.yml \
  --vault-password-file ~/.ansible-vault-pass --tags longhorn
```

(Installs `open-iscsi` + `nfs-common`, persists + loads `iscsi_tcp`, enables
`iscsid`. Idempotent; also runs as part of a full `deploy_k3s.yml`. The
crash-looping longhorn-manager pods recover on their own once `iscsid` is up.)

Manual equivalents, if ever needed without ansible:

- [ ] `open-iscsi` installed and `iscsid` enabled+running on **all 6 nodes**
      (Debian 13: `sudo apt install open-iscsi && sudo systemctl enable --now iscsid`).
- [ ] `iscsi_tcp` kernel module loads (`sudo modprobe iscsi_tcp`) — the Pi
      kernel (`6.12.x-rpt-rpi-2712`) ships it as a module; confirm once.
- [ ] `nfs-common` installed if RWX volumes or an NFS backup target will be
      used (`sudo apt install nfs-common`).
- [ ] `multipathd` either not running or configured to blacklist Longhorn
      devices (stock Debian doesn't run it; verify with
      `systemctl status multipathd`). A running unconfigured multipathd is
      the #1 upstream-documented Longhorn failure mode.
- [ ] Optional sanity: run the upstream environment check
      (`longhornctl check preflight`) or the checker DaemonSet from the
      Longhorn docs.
- [ ] Confirm each node's full path to the other storage nodes is **wired**
      (switch/AiMesh-unit uplinks — see above), then label:
      `kubectl label node <node> node.longhorn.io/create-default-disk=true`.
      Until at least one node is labeled Longhorn has no disks and PVCs
      against the `longhorn` StorageClass stay Pending (safe).
- [ ] k3s v1.35.1 ≥ chart's `kubeVersion: >=1.25.0` — OK (verified).
- [ ] arm64 — officially supported (all Longhorn images are multi-arch).

## Key settings (see `.config/lab/longhorn.yaml` for the full commentary)

- 3 replicas, hard anti-affinity (each replica on a distinct node).
- `reclaimPolicy: Retain` on the StorageClass — an accidental PVC delete or
  Argo prune must never take the last copy of state (#175).
- `concurrentReplicaRebuildPerNodeLimit: 2` — rebuilds share the 1 GbE LAN
  with the LIVE battery controller (zeus↔HA/MQTT); don't storm it.
- `nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod` —
  pods on a dead node get freed so volumes reattach elsewhere (the point of
  the card).
- `preUpgradeChecker.jobEnabled: false` — upstream-documented requirement
  for Argo CD installs (helm-hook Job is incompatible).

## Backups (backup target: CIFS on nas001, since 2026-10-08)

**Target:** `cifs://nas001.lab.local/longhorn-backup` (`defaultBackupStore` in
`.config/lab/longhorn.yaml`). The share and NAS user are **dedicated**: share
`longhorn-backup`, its own DSM user with read/write on that share only. This is
the same separation as `cortana-backup`, with no overlap with `zeus-data`.
Credentials are the SealedSecret `longhorn-backup-credentials`
(`CIFS_USERNAME`/`CIFS_PASSWORD`), sealed into `.config/lab/longhorn-config.yaml`
by `.scripts/seal-longhorn-cifs.sh`. The script prompts without echo, and
re-running it rotates the credentials. NFS was the earlier preference; the owner
chose CIFS on 2026-10-08 because NFS is off on the NAS and SMB is already on.
All 6 nodes have `cifs-utils` and `nfs-common`.

**What is backed up:** only volumes that opt in to a recurring-job group.
Nothing uses Longhorn's built-in `default` group, so a new volume is never backed
up by accident. That matters because Prometheus and Jaeger churn about 35G and
are not worth the NAS space.

| RecurringJob | Task | Schedule | Retain | Concurrency | Members |
|---|---|---|---|---|---|
| `nas-daily` | backup (snapshot + incremental block backup) | 04:30 daily | 14 | 1 | see members below |

Members of `nas-daily`, and where the label is set:

| Volume (PVC) | Label set by | Why it is backed up |
|---|---|---|
| `harbor/harbor-registry` | **by hand** (Harbor chart cannot label its PVC) | image layers; the DB is pg_dump'ed at 04:00 |
| `influxdb/influxdb-influxdb2` | **by hand** (influxdb2 chart cannot label its PVC) | point-in-time copy of the TSDB on top of the nightly + hourly `influx backup` |
| `hermes/hermes-cortana-state` | git: `.config/lab/hermes.yaml` `persistence.labels` | Cortana's irreplaceable state (#175); `hermes-backup` keeps a file-level copy |
| `observability/kube-prometheus-stack-grafana` | git: `.config/lab/observability.yaml` `grafana.persistence.extraPvcLabels` | plugin state and UI-made changes are not in git |
| `ceres/ceres-pg-1`, `-2` | git: `.config/lab/ceres.yaml` `postgres.inheritedLabels` (CNPG `inheritedMetadata`, also future instances) | Annona's config DB, on top of the 03:45 pg_dump |
| `ceres/ceres-vertumnus-<unit>-ledger` | git: `.config/lab/ceres.yaml` `ledger.labels` (every unit) | what each unit has learned (ADR-0019) |
| `jupiter-central/jupiter-pg-1`, `-2` | git: `.config/lab/jupiter-central.yaml` `reporting.postgres.inheritedLabels` | the savings ledger, on top of the 03:50 pg_dump |

Deliberately **not** backed up: Prometheus (30G of churn, retention-bound) and
Jaeger (traces), plus Alertmanager silences. Also left out are the rebuildable
caches and artifacts: Harbor's valkey, trivy and jobservice logs,
`price-service-cache`, and `forecast-artifacts` (the trainer rebuilds them).
The `harbor-pg` volume is covered by its dump.

04:30 is after every database dump (InfluxDB 03:30, Annona 03:45, jupiter
ledger 03:50, Harbor 04:00), so the Harbor dump is always older than the layer
backup. Concurrency 1 keeps the 1 GbE LAN calm; the battery controller rides on
it too. Backups are incremental: after the first full copy, only changed 2 MiB
blocks travel.

**Adding a volume** (labels on its PVC; Longhorn syncs them to the volume):

```sh
kubectl -n <ns> label pvc <pvc> recurring-job.longhorn.io/source=enabled \
  recurring-job-group.longhorn.io/nas-daily=enabled
```

Add it to the members table above and to the comment in `.config/lab/longhorn-config.yaml`.
The labels live only on the cluster object: Argo's server-side apply leaves
labels it does not own alone, but a **recreated PVC loses them**. Re-check after
any PVC recreation with
`kubectl get volumes.longhorn.io -n longhorn-system -L recurring-job-group.longhorn.io/nas-daily`.
Charts that let you set PVC labels (CNPG `inheritedMetadata`, most upstream
charts) should carry them in git instead. The Harbor chart cannot, which is why
`harbor-registry` is labelled by hand.

**Checks:**

```sh
kubectl -n longhorn-system get backuptarget default        # AVAILABLE must be true
kubectl -n longhorn-system get backupvolumes,backups       # what exists on the NAS
kubectl -n longhorn-system get recurringjobs
```

**Alerts** (`templates/prometheusrule.yaml`, group `longhorn-backups`; cerberus
turns a firing alert into a Trello card):

- `LonghornBackupFailed`: a Backup object is in Error/Unknown for 10m. It keeps
  firing until the failed backup is deleted. Fix the cause, then delete it.
- `LonghornBackupStale`: a volume with backups has had no new completed backup
  for `backupAlerts.maxAge` (26h). This catches a stopped `nas-daily`
  CronJob, an unavailable target, or a lost group label.

A volume that was labelled but has **never** completed a backup is not covered
by the stale alert. Check `kubectl -n longhorn-system get backupvolumes` after
adding one.

**Restore a volume:** in the Longhorn UI choose Backup → the volume → Restore
Latest Backup, into a new volume. Then create a PV/PVC for it under the
original name, while the workload is scaled to 0 and its Argo auto-sync is
paused. That is the same scale-down and PVC-recreate dance as the #235 InfluxDB
migration runbook. For Harbor, restore the database dump first
(platform/harbor-config/README.md "Backups").

**Disaster recovery note:** the backups are useless without the sealed-secrets
controller key (to unseal the credentials) or the NAS user's password. Longhorn
can also read the share from a freshly installed cluster once the target and
credentials are set again.

## UI — HTTPS-only gateway route, INTERIM until SSO (#233; was port-forward-only per #193)

The Longhorn UI is **UNAUTHENTICATED admin**: it can delete volumes, replicas
and backups. The 2026-07-12 security review (#193) removed its gateway route
entirely (port-forward-only) because TLS alone is encryption, not auth, and a
per-route LAN allow-list is not cleanly supported on the shared Cilium gateway
(gateway traffic reaches the backend as the reserved `ingress` identity; the
LAN source IP is already proxied away).

**Owner decision 2026-08-14 (#233):** with no SSO in the lab yet, the route is
re-added **HTTPS-only** as an interim: `https://longhorn.lab.local` (lab-CA
cert `longhorn-server-tls` from `templates/certificate.yaml`, dedicated
`longhorn-https` SNI listener in `.config/lab/gateway.yaml`, HTTPRoute
parented ONLY to that listener; `http://longhorn.lab.local` is answered by a
redirect-only route that 302s to https — content is never served over plain
HTTP). The namespace CNP
re-admits the gateway `ingress` identity
(`templates/ciliumnetworkpolicy.yaml`). This knowingly re-accepts the #193
risk — any LAN host can reach an unauthenticated admin UI, now encrypted —
until the **SSO rollout (card #232)** puts real authentication (oauth2-proxy /
authentik / similar) in front of this route. Treat #232 as the closing half of
this interim.

The RBAC-gated path still works and remains the recommended one for anything
destructive:

```sh
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# http://localhost:8080
```

The `longhorn.lab.local` A record in `.config/lab/coredns-lab.yaml` predates
all of this and is unchanged.

## Monitoring

- **ServiceMonitor**: upstream chart's (`metrics.serviceMonitor.enabled`),
  labeled `release: kube-prometheus-stack`, scraping `longhorn-manager`
  (:9500, service `longhorn-backend`).
- **Dashboard**: `dashboards/longhorn.json` (upstream grafana.com **13032**,
  datasource pinned to uid `prometheus` per repo convention), shipped as a
  sidecar ConfigMap.
- **Alerts** (`templates/prometheusrule.yaml`): `LonghornVolumeFaulted`
  (critical), `LonghornVolumeDegraded`, `LonghornRebuildStorm`,
  `LonghornNodeNotReady`, `LonghornNodeStorageAboveThreshold`. ⚠ Post-deploy
  checklist: verify the metric names against a live scrape
  (`longhorn-backend:9500/metrics`) — they follow the 1.11 upstream metrics
  reference but could not be checked pre-deploy (mqtt-README convention is
  live-verified names).

## Ops runbook

- **Node maintenance (planned)**: Longhorn UI → Node → *Edit node and disks*
  → disable scheduling + request eviction, or just cordon+drain — volumes
  stay served by the other replicas. Uncordon and re-enable when back.
  Cluster is LIVE (battery controller, DNS): schedule reboots with the owner.
- **Node/disk lost (unplanned)**: expect `LonghornVolumeDegraded` then
  automatic rebuilds (max 2 concurrent per node). Nothing to do unless
  degradation persists >15m — then check the UI for stuck rebuilds.
- **Volume faulted**: do not detach/delete anything. Restore the last backup
  from the backup target to a new volume (UI → Backup → Restore), repoint
  the PVC, investigate cause. Until a backup target is configured the only
  fallback is application-level state reconstruction — configure the target
  before migrating anything important (phase 3 gate).
- **Upgrades**: bump `repos.longhorn.targetRevision` in
  `.config/shared/values.yaml` (one minor at a time — Longhorn does NOT
  support skipping minors) and let Argo sync. Check the upstream upgrade
  notes first; never downgrade.
- **What lives on Longhorn vs elsewhere**: see [`docs/storage.md`](../../docs/storage.md).
