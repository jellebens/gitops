# coredns-lab — in-cluster `lab.local` secondary (AXFR replica)

Runs a small CoreDNS deployment in `kube-system` that is a **secondary**
(read-only AXFR replica) of the `lab.local` zone. The **primary/master is the
Synology DS918+ DNS Server** (`192.168.50.144`).

The cluster is deliberately *only a replica*: DS918 stays authoritative, so LAN
name resolution never depends on k8s being healthy (no circular dependency). The
in-cluster copy gives a local cached copy of the zone — the cluster's own CoreDNS
forwards `lab.local` to this secondary **first** and falls back to the DS918
(`.144`) if it's down (see `coredns-config`), and LAN clients can use it as a
second resolver.

## How it's deployed

| | |
|---|---|
| Argo CD app | `coredns-lab` (project `platform-services`, sync-wave `15`) |
| Namespace | `kube-system` |
| App definition | [`applications/templates/coredns-lab/coredns-lab-app.yaml`](../../applications/templates/coredns-lab/coredns-lab-app.yaml) |
| Env values | `.config/<env>/coredns-lab.yaml` |

## Pieces

- **Deployment + ConfigMap (`coredns-lab`)** — CoreDNS with the `secondary`
  plugin: `transfer from 192.168.50.144`. Pulls the zone via AXFR, caches it,
  refreshes on the SOA timers. 2 replicas, anti-affinity across nodes.
- **Service (`coredns-lab`, LoadBalancer)** — VIP `192.168.50.180` (Cilium
  `platform` pool), `53/UDP` + `53/TCP`. LAN clients can use it as a **secondary**
  resolver (DS918 stays first in DHCP).
- **Cluster forwarding is owned by `coredns-config`, not here.** That app's
  `coredns-custom` ConfigMap forwards `lab.local` to `[.180, .144]` with
  `policy sequential` — this secondary first, DS918 fallback. `clusterForward` in
  this chart stays **disabled** so two Argo apps don't fight over `coredns-custom`.

## DS918 side (one-time)

The master must permit the zone transfer. In **DNS Server → Zones → `lab.local`
→ Edit → Zone Transfer**: add a **Subnet** rule `192.168.50.0` / `255.255.255.0`
(pods egress to the LAN SNAT'd to a node IP, so the whole subnet covers all
nodes). Optionally enable **NOTIFY** so edits push immediately instead of waiting
for the SOA refresh interval.

## Verify

```sh
kubectl -n kube-system rollout status deploy/coredns-lab
kubectl -n kube-system get svc coredns-lab          # EXTERNAL-IP = 192.168.50.180
dig @192.168.50.180 nas001.lab.local +short         # from the LAN -> 192.168.50.2
kubectl run -n default dnstest --rm -it --image=busybox --restart=Never -- \
  nslookup nas001.lab.local                         # from a pod (via cluster CoreDNS)
```

If the transfer is refused, the pod logs show `axfr ... no transfer`:
`kubectl -n kube-system logs deploy/coredns-lab` — fix the DS918 transfer ACL.
