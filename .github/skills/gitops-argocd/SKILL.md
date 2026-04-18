---
name: gitops-argocd
description: 'Troubleshoot and document Argo CD and Helm GitOps failures end to end. Use for ComparisonError, failed to load target state, helm template errors, chart version not found, sync drift, repository secret issues, and ingress reachability debugging.'
argument-hint: 'What Argo CD error or GitOps symptom should be investigated? Include app name, error text, and environment.'
user-invocable: true
---

# GitOps Argo CD Workflow

## See Also
- General documentation workflow: ../documentation/SKILL.md

## When to Use
- Argo CD `ComparisonError` or `Failed to load target state`
- Helm render or fetch failures in Argo CD apps
- Invalid chart or target revision errors
- Duplicate application resources
- Sync drift caused by rotating certificate fields
- Ingress host resolves but endpoint is unreachable

## Inputs to Collect
1. Full Argo CD error text
2. Application name and namespace
3. Chart source and target revision
4. Values files used by Argo CD
5. Whether issue is render-time, sync-time, or runtime network access

## Procedure
1. Capture the exact failure message and command context.
2. Classify the failure domain: render, fetch, apply, diff, or networking.
3. Locate source of truth files for templates and values.
4. Apply the smallest possible config/template fix.
5. Validate with Helm render or Argo CD CLI checks.
6. Confirm app sync and health status.
7. Document root cause, fix, and rollback notes.

## Decision Branches
- If error contains `nil pointer`:
  Check for missing values keys and use safe defaults for nested values.
- If error contains `chart version not found`:
  Query upstream chart versions and pin a valid `targetRevision`.
- If error contains `server address unspecified`:
  Configure Argo CD CLI login context before app-level actions.
- If host resolves but connection fails:
  Separate DNS, service listener, and route reachability checks.
- If resource appears multiple times:
  Check duplicate `kind/namespace/name` across templates.

## Validation Commands
1. `argocd app list`
2. `argocd app get <app-name>`
3. `argocd app sync <app-name>`
4. `argocd app wait <app-name> --sync --health`
5. `helm search repo <repo/chart> --versions`
6. `kubectl -n <ns> get ingress,svc,pods -o wide`

## Diff Noise Controls
Use `ignoreDifferences` only for known mutable fields, such as:
- Webhook `caBundle`
- Roll annotations used for restarts
- Secret cert data fields (`ca.crt`, `ca.key`, `tls.crt`, `tls.key`) where rotation is expected

## Completion Checks
1. Root cause is tied to a concrete file and key.
2. Fix is minimal and reproducible.
3. Validation confirms both sync and health.
4. Temporary workaround and permanent fix are both documented.
