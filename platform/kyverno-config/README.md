# kyverno-config

Baseline [Kyverno](https://kyverno.io) cluster policies. The engine itself is
installed by the `kyverno` Argo CD app (upstream chart, pinned in
[`.config/shared/values.yaml`](../../.config/shared/values.yaml) under
`repos.kyverno`); this chart only carries our `ClusterPolicy` resources, synced
by the `kyverno-config` app one wave later.

## Safety stance — Audit only

This cluster runs a **live battery controller** (jupiter-lar). Kyverno is
therefore deployed so it can never interfere with admissions:

- Every policy has `validate.failureAction: Audit` — violations produce
  PolicyReports, nothing is ever rejected.
- Every policy sets `webhookConfiguration.failurePolicy: Ignore` — if the
  Kyverno admission webhook is down, API requests pass through untouched.
- Kyverno's default resource filters exclude `kube-system` and the `kyverno`
  namespace.

Promoting a policy to `Enforce` is a deliberate per-policy decision: review its
PolicyReports first (`kubectl get policyreports -A`), exempt the legitimate
offenders, and only then override `policies.failureAction` — via
[`.config/lab/kyverno.yaml`](../../.config/lab/kyverno.yaml) for a blanket
change, or per-policy in the template.

## Policies

| Policy | Category | What it flags |
| --- | --- | --- |
| `disallow-privileged-containers` | PSS Baseline | `securityContext.privileged: true` on any container |
| `disallow-host-namespaces` | PSS Baseline | `hostNetwork`, `hostPID`, or `hostIPC` set to true (expect hits from CSI/CNI node pods — exempt, don't enforce blindly) |
| `disallow-latest-tag` | Best Practices | images with no tag or the `latest` tag |

Each policy can be toggled via `policies.<name>.enabled` in values.

## Operations

```sh
# Render locally
helm template kyverno-config ./platform/kyverno-config \
  -f .config/shared/values.yaml -f .config/lab/values.yaml -f .config/lab/kyverno.yaml

# What is being flagged?
kubectl get policyreports -A
kubectl get clusterpolicyreports

# Engine health
argocd app get kyverno --core
kubectl -n kyverno get pods
```

The Kyverno images are multi-arch (arm64 OK for this cluster). All controllers
run single-replica; the chart's defaults are otherwise untouched.
