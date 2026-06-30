# coredns-lab — in-cluster `lab.local` authoritative primary

Runs a small CoreDNS deployment in `kube-system` that is the **authoritative
primary** for the `lab.local` zone, served from a **zone file kept in git** (the
`file` plugin). The Synology DS918+ (`192.168.50.144`) is now a **slave** that
pulls the zone via AXFR.

Because LAN clients use this deployment's VIP as their **primary resolver**
(DHCP DNS1), it is also a **full recursive forwarder**: a catch-all `.:53` block
forwards everything that isn't `lab.local` to the router (`192.168.50.1`, which
answers home `.local` names and recurses to the internet) with `1.1.1.1` as a
fallback. The DS918 is handed out as **DNS2**, so if the whole cluster is down
clients still resolve `lab.local` (from the slave) and the internet (DS918
recurses independently).

## How it's deployed

| | |
|---|---|
| Argo CD app | `coredns-lab` (project `platform-services`, sync-wave `15`) |
| Namespace | `kube-system` |
| App definition | [`applications/templates/coredns-lab/coredns-lab-app.yaml`](../../applications/templates/coredns-lab/coredns-lab-app.yaml) |
| Env values | `.config/<env>/coredns-lab.yaml` |

## Pieces

- **Zone ConfigMap (`coredns-lab-zone`)** — the authoritative `lab.local` zone
  file (`db.lab.local`), rendered verbatim from `corednsLab.zoneFile` in
  `.config/<env>/coredns-lab.yaml`. **This is the source of truth for the zone —
  edit it here.** Bump the SOA serial on every change (see below).
- **Corefile ConfigMap (`coredns-lab`)** — two server blocks:
  `lab.local:53` (`file` plugin + `transfer { to <slaves> }` to allow AXFR /
  send NOTIFY) and a catch-all `.:53` (`forward` to `corednsLab.upstreams`).
- **Deployment (`coredns-lab`)** — 3 replicas, anti-affinity across nodes. The
  pods roll automatically when the Corefile or zone changes (`checksum/config`).
- **Service (`coredns-lab`, LoadBalancer)** — VIP `192.168.50.180` (Cilium
  `platform` pool), `53/UDP` + `53/TCP`. This is DHCP **DNS1** for LAN clients.
- **Cluster forwarding is owned by `coredns-config`, not here.** That app's
  `coredns-custom` ConfigMap forwards `lab.local` to `.180` so pods resolve
  `*.lab.local`. `clusterForward` in this chart stays **disabled** so two Argo
  apps don't fight over `coredns-custom`.

## Editing the zone — IMPORTANT

1. Edit the records under `corednsLab.zoneFile` in `.config/<env>/coredns-lab.yaml`.
2. **Bump the SOA `serial`** (convention: `YYYYMMDDnn`). The DS918 slave keys off
   the serial — if you don't bump it, the slave won't pull your change.
3. Commit/push to `main`; Argo syncs, the pods roll, the `file` plugin loads the
   new zone and NOTIFYs the slave.

## DS918 side (one-time, see cutover)

Reconfigure the `lab.local` zone on the DS918 from **master → slave**, pulling
from `192.168.50.180`. Keep its recursion/forwarding enabled so it can still
serve internet lookups for clients that fail over to it as DNS2.

## Verify

```sh
kubectl -n kube-system rollout status deploy/coredns-lab
kubectl -n kube-system get svc coredns-lab          # EXTERNAL-IP = 192.168.50.180
dig @192.168.50.180 nas001.lab.local +short         # -> 192.168.50.2 (authoritative)
dig @192.168.50.180 k3s.lab.local +short            # -> 192.168.50.151
dig @192.168.50.180 google.com +short               # catch-all forward -> internet
dig @192.168.50.180 lab.local AXFR                   # works from .144; refused elsewhere
```

Local render + parse check (no cluster needed):

```sh
helm template coredns-lab platform/coredns-lab -f .config/lab/coredns-lab.yaml
# then boot the real binary against the rendered Corefile/zone with docker to
# confirm it parses and resolves (see commit history / session notes).
```
