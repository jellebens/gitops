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

## Branching & Release Flow (GitFlow — since 2026-07-02)
- **All card/feature work branches off `develop` and merges back into `develop`
  via PR** (`card-<shortId>` branches; PR base `develop`). Never commit work
  directly to `develop` or `master`.
- **Nothing deploys from develop.** Argo CD deploys from `master`. On the user's
  **release** command: bump the version once for the batch (zeus
  `pyproject.toml`), open ONE PR `develop` → `master` grouping every commit since
  the last release, and merge it (merge commit, not squash). **Merging that PR
  is the deploy**: for zeus, build+push the arm64 image from `master` first, then
  bump `landingzones/zeus/values.yaml` `image.tag` on gitops `develop` and
  include it in the gitops release PR; Argo reconciles when gitops `master`
  updates. See `.claude/skills/trello-agents/SKILL.md` "Release" for the exact
  procedure.
- Emergency hotfix direct-to-master only with the user's explicit go-ahead; port
  it back to `develop` immediately after.

## Deployment Requests
- When the user says "deploy the changes", treat that as: check the worktree, run the relevant Helm render/checks, commit the scoped changes, push the current branch, sync the appropriate Argo CD app with `argocd app sync <app> --core`, then monitor it with `argocd app wait <app> --core --sync --health --timeout 300`. (Since 2026-07-02, routine changes reach `master` only via the release PR — see Branching & Release Flow.)
- Choose the Argo CD app from the changed chart or template path. For example, changes under `landingzones/openclaw/` sync the `openclaw` app, and changes under `applications/` sync the app-of-apps layer.
- If the change affects a workload, also check the rollout, pods, and recent logs after Argo reports healthy.

## Conventions To Preserve
- Argo `Application` resources use `sources` with a chart source plus a values ref source when env values are needed.
- Keep sync policy consistent:
  - `automated.prune: true`
  - `automated.selfHeal: true`
  - `syncOptions`: `CreateNamespace=true`, `ServerSideApply=true`
- Use sync waves for ordering (for example config apps before dependent apps).

## Known Pitfalls
- **Gateway UI exposure is HTTP-only unless a per-hostname HTTPS listener exists.** Web UIs are exposed via the shared Cilium gateway (VIP `192.168.50.200`, `gateway-config`): an A record + **zone serial bump** in `.config/lab/coredns-lab.yaml` plus an HTTPRoute. The shared `http` listener (port 80) serves any `*.lab.local` hostname, but **HTTPS needs its own listener + lab-CA certificate per hostname** (the argocd/hermes/influxdb pattern: a `tlsCertificate` from `lab-ca-issuer` + a dedicated `<name>-https` listener the HTTPRoute parents to via `sectionName`). A service without one (grafana, longhorn) is reachable ONLY at `http://<name>.lab.local` — browsers auto-upgrading to `https://` make it look down (connection refused on 443) even though the pod, route, and DNS are all healthy. When adding a UI, either ship the HTTPS listener+cert with it or state `http://` explicitly in its README.
- In Argo `Application` specs, `spec.sources[].helm.values` must be a string block, not a YAML object.
- `argocd app sync --force` can conflict with `ServerSideApply=true` and produce `--force cannot be used with --server-side`; retry without `--force` unless replacement is required.
- Public ACME issuers cannot issue certificates for `.local` domains; for lab domains use a non-public issuer (for example self-signed/internal CA).
- LAN hosts are not resolvable in-cluster by default: mDNS `.local` names (e.g. `vesta.local`) and DHCP hostnames return `NXDOMAIN` through CoreDNS. Add a forward in [`platform/coredns-config`](platform/coredns-config) (an exact host, or a distinct suffix like `lab.local` — **never the bare `local` zone**, which shadows `cluster.local` and breaks service discovery). SMB/CSI mounts resolve through cluster CoreDNS (`csi-smb-node` is `ClusterFirstWithHostNet`), so the same forward fixes them. Address NAS shares by name, not a static IP, which goes stale on DHCP renewal.
- `gh` CLI is installed in WSL (`/usr/bin/gh`, v2.45.0) and authed as `jellebens` over SSH, so `gh pr create`/`merge`/`checks` work. **But `gh pr edit` is broken here** — it fails with a GraphQL `Projects (classic) is being deprecated … repository.pullRequest.projectCards` error before applying the change. To edit a PR body (or title), patch via the REST API instead, which skips that path: `gh api --method PATCH repos/jellebens/<repo>/pulls/<n> -F body=@<file>` (use `-F key=@file` to read the field from a file and dodge shell-quoting). Also avoid multi-line `--body`/heredocs through `wsl -- bash -c '…'`: backticks/`$()` in markdown get shell-expanded and mangle the body — write the body with the file tools and pass `--body-file`.
- Parallel Trello-agent worktrees on this Windows-host + WSL repo are risky: the Agent tool creates the worktree under a `//wsl.localhost/...` UNC path whose `.git` gitdir is **unreachable from inside WSL**. Agents' Read/Edit can silently land in the **main** working tree (the POSIX path) instead of the worktree, and a later `git restore`/`checkout` meant to "clean" main then discards any *uncommitted* changes there (unstaged edits are unrecoverable — never hit the object store). Before a parallel worktree run, **commit or stash the main working tree first**. The branch commits themselves are fine — they land in the shared object store and are reachable from the WSL-side main repo via `git -C <repo> log <branch>` (merge them from there).
- **Sturdier fix — work in a sibling WSL worktree (not the harness one).** The reason edits leak is that the harness worktree sits *inside* the main tree with a UNC gitdir WSL git can't resolve, so from WSL `git rev-parse --show-toplevel` inside it returns the **main** repo — it's indistinguishable from main. Instead of relying on `.claude/worktrees/…`, create a sibling worktree with WSL git, outside the main tree, and do all edits/commits there: `git -C /home/jelle/repos/gitops worktree add /home/jelle/repos/gitops-card-<id> -b card-<id> origin/develop`. Because WSL git created it, its gitdir is a POSIX path WSL resolves, `--show-toplevel` returns the worktree, and edits stay isolated end-to-end (no Windows-git dance, no leak). This is exactly the pattern the zeus-repo cards use (`/home/jelle/repos/zeus-card-<id>`) — zero incidents across the 2026-07-02 batch, vs. a leak on every gitops card that used the harness worktree. A trivial one-line change can instead be made inline on a throwaway branch in the main tree (no worktree at all).

## Local Agent Guardrails
- Command approval hook is enabled at [.github/hooks/command-approval.json](.github/hooks/command-approval.json).
- Hook logic lives at [.scripts/copilot-command-approval.sh](.scripts/copilot-command-approval.sh).
- Keep dangerous git/file-destruction commands blocked by default.
