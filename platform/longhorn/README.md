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
StorageClass (NOT the default — `local-path` stays default) and the control
plane, but **zero storage capacity exists until the owner labels nodes**
(`createDefaultDiskLabeledNodes: true`). No data moves automatically; the
pilot migration (hermes state) is phase 3, a separate card.

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

## Backup target (decision pending — nothing configured at deploy)

Target device: DS918 NAS `nas001.lab.local` (192.168.50.144). Repo evidence:
the NAS already serves **SMB** shares consumed in-cluster via csi-driver-smb
(`smb` → influxdb-backups/zeus-reports, `smb-cortana` → hermes-backup); no
NFS or S3 usage exists in the repo today. Longhorn supports `nfs://`,
`cifs://` and `s3://` backup targets. Options, preferred first:

1. **NFS (recommended)** — most battle-tested Longhorn target, no
   credentials to seal. Owner enables NFS on DSM + creates a `longhorn-backup`
   shared folder → set `defaultSettings.backupTarget:
   nfs://nas001.lab.local:/volume1/longhorn-backup`.
2. **CIFS** — no new NAS service (SMB already on), but needs sealed
   credentials (`CIFS_USERNAME`/`CIFS_PASSWORD` in the
   `longhorn-backup-credentials` SealedSecret placeholder in this chart) and
   is the less-proven path in Longhorn.
3. **S3/MinIO** — would mean running MinIO on the DS918 or in-cluster; more
   moving parts than this backup need justifies. Rejected for now.

The commented-out `backupTarget` lines in `.config/lab/longhorn.yaml` are the
only wiring needed once the owner enables the share. Do **not** invent NAS
credentials; seal real ones with kubeseal (controller `sealed-secrets`, ns
`argocd`) when CIFS/S3 is chosen. After the target works, add a
`RecurringJob` (snapshot + backup schedule) — part of the phase-3 card.

## UI

Not exposed via LB/gateway (would need auth in front — Longhorn UI has
none). Port-forward when needed:

```sh
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# http://localhost:8080
```

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
