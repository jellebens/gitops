# coredns-lab — in-cluster `lab.local` secondary (AXFR replica)

Runs a small CoreDNS deployment in `kube-system` that is a **secondary**
(read-only AXFR replica) of the `lab.local` zone. The **primary/master is the
Synology DS918+ DNS Server** (`192.168.50.102`).

The cluster is deliberately *only a replica*: DS918 stays authoritative, so LAN
name resolution never depends on k8s being healthy (no circular dependency). The
in-cluster copy adds fast, local `*.lab.local` resolution for pods and a second
resolver for LAN clients.

## How it's deployed

| | |
|---|---|
| Argo CD app | `coredns-lab` (project `platform-services`, sync-wave `15`) |
| Namespace | `kube-system` |
| App definition | [`applications/templates/coredns-lab/coredns-lab-app.yaml`](../../applications/templates/coredns-lab/coredns-lab-app.yaml) |
| Env values | `.config/<env>/coredns-lab.yaml` |

## Pieces

- **Deployment + ConfigMap (`coredns-lab`)** — CoreDNS with the `secondary`
  plugin: `transfer from 192.168.50.102`. Pulls the zone via AXFR, caches it,
  refreshes on the SOA timers. 2 replicas, anti-affinity across nodes.
- **Service (`coredns-lab`, LoadBalancer)** — VIP `192.168.50.180` (Cilium
  `platform` pool), `53/UDP` + `53/TCP`. This is the address LAN clients use as a
  **secondary** resolver — **DS918 stays first** in DHCP.
- **`coredns-custom` ConfigMap** — makes the cluster's own (k3s) CoreDNS forward
  `lab.local` → the secondary, so pods resolve `*.lab.local` (no more mDNS / no
  hardcoded `192.168.50.18` / `.102`). Gated by `clusterForward.enabled`; turn
  it off if k3s CoreDNS custom config is owned by Ansible.

## DS918 side (one-time)

The master must permit the zone transfer. In **DNS Server → Zones → `lab.local`
→ Edit → Zone Transfer**: enable transfer and allow the **k3s node IPs** (pods
egress to the LAN are SNAT'd to the node IP, so a single pod IP won't match).
Optionally enable **NOTIFY** so edits push immediately instead of waiting for the
refresh interval.

## Verify

```sh
kubectl -n kube-system rollout status deploy/coredns-lab
kubectl -n kube-system get svc coredns-lab          # EXTERNAL-IP = 192.168.50.180
dig @192.168.50.180 vesta.lab.local +short          # from the LAN
kubectl run -n default dnstest --rm -it --image=busybox --restart=Never -- \
  nslookup vesta.lab.local                          # from a pod (via cluster CoreDNS)
```

If the transfer is refused, the pod logs show `axfr ... no transfer`:
`kubectl -n kube-system logs deploy/coredns-lab` — fix the DS918 transfer ACL.
