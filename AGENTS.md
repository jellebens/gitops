# GitOps Agent Guide

This repository manages Argo CD app-of-apps and platform service configuration via Helm charts.

## Start Here
- Bootstrap command: [README.md](README.md)
- Argo CD troubleshooting workflow: [.github/skills/gitops-argocd/SKILL.md](.github/skills/gitops-argocd/SKILL.md)
- Documentation workflow: [.github/skills/documentation/SKILL.md](.github/skills/documentation/SKILL.md)
- Platform service scaffolding agent: [.github/agents/platform-service.agent.md](.github/agents/platform-service.agent.md)

## Repository Shape
- `bootstrap/`: installs the top-level Argo CD `bootstrap` Application.
- `applications/`: child Argo CD Applications (app-of-apps layer).
- `platform/*-config/`: Helm charts for platform resource configuration.
- `.config/shared/` and `.config/<env>/`: shared and environment values consumed through Argo CD multi-source `$values` references.
- `projects/`: Argo CD `AppProject` definitions.

## High-Value Commands
- Render app-of-apps chart:
  - `helm template applications ./applications -f .config/shared/values.yaml -f .config/lab/values.yaml`
- Render platform chart with env overrides:
  - `helm template <release> ./platform/<chart> -f .config/shared/values.yaml -f .config/lab/values.yaml -f .config/lab/<component>.yaml`
- Argo status and sync (core mode):
  - `argocd app list --core`
  - `argocd app get <app> --core`
  - `argocd app sync <app> --core`
  - `argocd app wait <app> --core --sync --health --timeout 300`

## Conventions To Preserve
- Argo `Application` resources use `sources` with a chart source plus a values ref source when env values are needed.
- Keep sync policy consistent:
  - `automated.prune: true`
  - `automated.selfHeal: true`
  - `syncOptions`: `CreateNamespace=true`, `ServerSideApply=true`
- Use sync waves for ordering (for example config apps before dependent apps).

## Known Pitfalls
- In Argo `Application` specs, `spec.sources[].helm.values` must be a string block, not a YAML object.
- `argocd app sync --force` can conflict with `ServerSideApply=true` and produce `--force cannot be used with --server-side`; retry without `--force` unless replacement is required.
- Public ACME issuers cannot issue certificates for `.local` domains; for lab domains use a non-public issuer (for example self-signed/internal CA).

## Local Agent Guardrails
- Command approval hook is enabled at [.github/hooks/command-approval.json](.github/hooks/command-approval.json).
- Hook logic lives at [.scripts/copilot-command-approval.sh](.scripts/copilot-command-approval.sh).
- Keep dangerous git/file-destruction commands blocked by default.
