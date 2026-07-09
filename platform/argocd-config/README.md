# argocd-config

GitOps configuration for the cluster's Argo CD install. Synced by the
`argocd-config` Argo `Application` (`applications/templates/argocd/argocd-config-app.yaml`,
sync-wave `5`), with `automated.selfHeal: true` and `ServerSideApply=true`.

## What this chart owns (and what it does NOT)

The **Argo CD install itself** — the `argocd-repo-server`, `argocd-server`,
`argocd-application-controller`, etc. Deployments, their probes and resources —
is a **stock `argo-cd` Helm release** (release name `argocd`, chart
`argo-cd-9.4.17`, appVersion `v3.3.6`) applied **out-of-band at bootstrap**
(see repo root `README.md`). It is **not** reconciled by Argo/GitOps.

This chart layers a small set of **partial patches / ConfigMaps** on top of that
Helm-owned install so the important knobs are declarative and version-controlled:

- `cm.yaml` — `argocd-cm` (`application.resourceTrackingMethod: annotation`).
- `cmd-params.yaml` — `argocd-cmd-params-cm` (`server.insecure`).
- `service.yaml` — patches the `argocd-server` Service to `ClusterIP` (reached
  via the gateway).
- `repo-server-tuning.yaml` — patches the `argocd-repo-server` Deployment
  (resources + liveness probe). **See below.**

These patches work because resource tracking is by **annotation** and Argo
applies with **ServerSideApply** (`--force-conflicts`), so Argo takes co-ownership
of just the patched fields from the `helm` field-manager without replacing the
whole object.

## repo-server tuning (card #159)

**Symptom:** `argocd-repo-server` was crash-looping — 477+ restarts over ~5 days,
killed every few minutes. While it was down, Application comparisons failed with
`ComparisonError: ... dial tcp <repo-server>:8081 connect: no route to host`, so
syncs only succeeded during its brief up-windows (the `mqtt` app was stuck
`sync=Unknown` for ~2 days).

**Root cause — liveness-probe flap, NOT OOM.** Evidence:

- Last State `Terminated / Reason: Completed / Exit Code: 0` (clean SIGTERM,
  `got signal terminated ... clean shutdown`) — not `OOMKilled`.
- Events: `Killing ... failed liveness probe, will be restarted` and
  `Liveness probe failed: Get .../healthz?full=true: context deadline exceeded`.
- Live memory usage ~58Mi with **no resource requests/limits** (QoS
  `BestEffort`) — nowhere near an OOM.
- The stock chart's repo-server **liveness** probe hits `/healthz?full=true`
  with `timeoutSeconds: 1`. `full=true` does real work; whenever the repo-server
  is busy rendering a chart on the arm64 nodes, the health handler can't answer
  within 1s (logs show the healthcheck taking ~1.2s and being `context canceled`
  while a `GenerateManifest` ran ~3.9s) → 3 failures → kubelet kill.

**Fix** (`repoServer.tuning` in `values.yaml`):

- Liveness probe → lightweight `/healthz` (same endpoint readiness already
  uses), `timeoutSeconds: 5`, `periodSeconds: 30`, `failureThreshold: 5`.
  Readiness is left untouched so a genuinely wedged repo-server still stops
  receiving traffic.
- Add resource **requests** (cpu `50m`, memory `256Mi`) and a memory **limit**
  (`1Gi`) — moves the pod off `BestEffort` with headroom for helm rendering.
  No CPU limit, to avoid throttling that would slow the health check and
  re-trigger the loop.

`repoServer.tuning.enabled: false` disables the patch entirely (reverts to the
stock Helm-owned probe/resources on the next reconcile).

## Verify

```sh
helm template argocd-config ./platform/argocd-config \
  -f .config/shared/values.yaml -f .config/lab/values.yaml -f .config/lab/argocd.yaml \
  -s templates/repo-server-tuning.yaml

# validates against the live schema exactly as Argo applies it (SSA + force):
kubectl apply --server-side --force-conflicts \
  --field-manager=argocd-controller --dry-run=server -f <rendered-patch>.yaml
```

## Note: this is a partial patch on a Helm-owned Deployment

If the out-of-band `argocd` Helm release is ever `helm upgrade`d, Helm may
re-assert the stock probe values on the fields it still lists; Argo's `selfHeal`
then re-applies this patch on the next reconcile. If you upgrade the argo-cd
chart, re-check the repo-server probe/resource defaults against this patch.
