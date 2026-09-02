# chaos-mesh-config

Local config chart riding next to the upstream `chaos-mesh` chart (deployed by
the `chaos-mesh` Argo app from `.config/lab/chaos-mesh.yaml`). Same split as
`longhorn` / `longhorn-config`. Ships the repo-convention extra the upstream
chart can't: an **ingress-only CiliumNetworkPolicy** from birth.

Card **#189** (2026-07-12 security review): the Chaos Mesh dashboard was
exposed on the LAN with authentication disabled — an active, destructive
capability.

## The hole (as found)

- `.config/lab/chaos-mesh.yaml` set `dashboard.securityMode: false`, removing
  the token/RBAC gate (upstream default is `true`). Anyone reaching the
  dashboard could create chaos experiments — pod-kill, network
  partition/delay, IO fault — against any namespace, including the **LIVE
  battery path** (zeus / jupiter-lar / mqtt / HA).
- Two LAN-reachable paths to the auth-less dashboard:
  1. **Gateway route** `chaos-mesh.lab.local -> chaos-dashboard:2333` (HTTP)
     via the shared Cilium gateway (`.config/lab/gateway.yaml`).
  2. **NodePort** — the upstream chart defaults `dashboard.service.type` to
     `NodePort`, publishing the UI on every node IP (`30732 -> 2333`). This
     was live (`kubectl get svc -n chaos-mesh`) and is a path a namespace-wide
     ingress CNP can NOT close on its own (NodePort SNATs LAN clients to the
     node/`host` identity, which the CNP must allow for kubelet/apiserver).
- No CiliumNetworkPolicy on the namespace.

chaos-mesh is running but **unused**: no chaos experiment CRs exist anywhere
(repo grep + live `kubectl get podchaos,networkchaos,... -A` = none).

## The fix (card #189)

Three parts, all reversible, none touching live connectivity:

1. **Close the auth hole at the source** — `.config/lab/chaos-mesh.yaml`:
   `dashboard.securityMode: true` (restores the token gate; even port-forward
   access is authenticated).
2. **Remove every LAN path** to the dashboard:
   - drop the gateway route (`.config/lab/gateway.yaml`);
   - pin `dashboard.service.type: ClusterIP` (kills the NodePort).
   The dashboard is now reachable **only** via `kubectl port-forward`.
3. **Ingress-only CNP** (this chart) as the defense-in-depth boundary:
   nothing from `world` (the LAN) reaches any chaos-mesh pod.

The `chaos-mesh.lab.local` DNS A record in `.config/lab/coredns-lab.yaml` is
left in place on purpose — it harmlessly resolves to the gateway VIP but now
has no route (404). Touching the authoritative `lab.local` zone for a cosmetic
cleanup is not worth the DNS blast radius.

## The CiliumNetworkPolicy

`templates/ciliumnetworkpolicy.yaml`, gated by `networkPolicy.enabled`
(default `true`). Namespace-wide `endpointSelector: {}`, ingress-only,
`fromEntities: [cluster]` — mirrors the `longhorn` policy.

- **Ingress-only** → egress stays fully open (chaos-mesh still reaches the
  kube-apiserver and DNS). A broader egress default-deny is a separate,
  human-reviewed step.
- **`cluster`** covers all cluster pods plus the `host`/`remote-node`
  entities, so kubelet probes, kube-apiserver webhook calls (controller-manager
  webhooks) and intra-namespace daemon traffic keep working, while `world`
  (the LAN) is denied.
- The gateway `ingress` entity is deliberately **not** allowed — chaos-mesh
  has no gateway route (unlike longhorn), so there is nothing legitimate to
  permit there.

Check after deploy: `kubectl get cnp -n chaos-mesh` — **VALID must be True**
(Cilium 1.16 rejects a rule that mixes `fromEntities` + `fromEndpoints`; this
policy uses only `fromEntities`, so it is safe).

## Rollback

- **Disable the CNP:** `networkPolicy.enabled: false` in this chart's
  `values.yaml` -> release. Argo (prune + selfHeal) deletes the CNP; namespace
  returns to unpoliced.
- **Restore LAN access to the dashboard** (only if a chaos experiment is
  actually wanted): revert the `.config/lab/chaos-mesh.yaml` /
  `.config/lab/gateway.yaml` changes. Prefer keeping `securityMode: true`.
- **Emergency (human, live):** `kubectl delete cnp -n chaos-mesh chaos-mesh`.

## Deploy

Release-gated (Argo watches `master`). Merging the release PR is the deploy;
the config app syncs one wave after the `chaos-mesh` app (wave 21) so the
namespace exists first.
