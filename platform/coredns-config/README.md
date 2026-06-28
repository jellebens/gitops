# coredns-config — cluster CoreDNS custom forwarding

Renders the k3s **`coredns-custom`** ConfigMap (`kube-system`) so the cluster's
CoreDNS can resolve LAN hostnames it otherwise can't. k3s imports `*.server`
files from this ConfigMap as extra server blocks
(`import /etc/coredns/custom/*.server` in the Corefile); the `reload` plugin
picks up changes within ~30s (no pod restart).

Each `forwards` entry renders one `<name>:53` server block forwarding that name
(or zone) to one or more upstream resolvers.

## How it's deployed

| | |
|---|---|
| Argo CD app | `coredns-config` (project `platform-services`, sync-wave `1`) |
| Namespace | `kube-system` (manages the `coredns-custom` ConfigMap) |
| App definition | [`applications/templates/coredns-config/coredns-config-app.yaml`](../../applications/templates/coredns-config/coredns-config-app.yaml) |
| Env values | `.config/<env>/coredns-config.yaml` |

## Current forwards (lab)

| Name | Upstream(s) | Why |
|---|---|---|
| `vesta.local` | `192.168.50.1` (router) | Home Assistant + MQTT host (DHCP-reserved `.18`); the router serves the bare `.local` name |
| `lab.local` (whole zone) | `[192.168.50.180, 192.168.50.144]`, `policy sequential` | in-cluster secondary ([`coredns-lab`](../coredns-lab)) first, DS918 master fallback. Covers `nas001.lab.local`, etc. |

`to` may be a single IP or a list; a list renders
`forward . <ips> { policy <p> }` (`sequential` = try in order).

## Why this exists / safety

- **mDNS `.local` names don't resolve in-cluster.** Names like `vesta.local`
  are multicast-DNS (answered by the host on the LAN); CoreDNS forwards `.local`
  to a unicast resolver that returns `NXDOMAIN`, so pods and CSI mounts can't
  resolve them. This app points the specific names at a resolver that knows them.
- **Never forward the bare `local` zone.** `cluster.local` is a sub-zone of
  `.local`; a `local:53` block would win the longest-suffix match for every
  `*.svc.cluster.local` query and break in-cluster service discovery. Forward
  exact hosts (`vesta.local`) or distinct suffixes (`lab.local`) only —
  `lab.local` is safe because it is not a parent of `cluster.local`.
- **SMB/CSI mounts resolve through CoreDNS.** The `csi-smb-node` DaemonSet runs
  `dnsPolicy: ClusterFirstWithHostNet`, so mount targets like
  `//nas001.lab.local/...` resolve via the cluster CoreDNS (this app), not the
  node's resolver.

## Relationship to coredns-lab

This app owns **cluster forwarding** (the `coredns-custom` ConfigMap).
[`coredns-lab`](../coredns-lab) runs the in-cluster `lab.local` **secondary**
(AXFR replica of the DS918) that the `lab.local` forward points at first. Keep
`coredns-lab`'s `clusterForward` disabled so the two apps don't both manage
`coredns-custom`.

## Verify

```sh
kubectl -n kube-system get cm coredns-custom -o yaml
kubectl run -n default dnstest --rm -it --image=busybox --restart=Never -- \
  sh -c 'nslookup vesta.local; nslookup nas001.lab.local'
```
