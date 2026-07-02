# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repo.

## Read first

This repo's full agent guide lives in **[AGENTS.md](AGENTS.md)** — repository
shape, Argo CD conventions, high-value Helm/argocd commands, deployment-request
workflow, and known pitfalls. Treat it as the source of truth; the notes below
are Claude-/environment-specific additions, not a replacement.

## Stack

Argo CD + Helm GitOps. **Flux and Kustomize are NOT used** — do not suggest or
install them. Tooling: `argocd`, `helm`, `kubectl`, `kubeseal`, `jq`, `git`.

## Environment & shell

- The repo lives in **WSL** (`~/repos/gitops` in the `ubuntu` distro), but the
  Claude host is Windows. Run git/kubectl/helm/argocd through WSL:
  `wsl -d ubuntu -- bash -c '<cmd>'`. Prefer `git -C /home/jelle/repos/<repo>`
  with absolute paths.
- **Output can interleave** across WSL invocations. When a value matters
  (branch, HEAD, remote URL), run **one isolated command** and avoid compound
  `&&`/`echo` chains — those have produced corrupted/garbled output here.
  Commands still *execute* correctly; only the echoed output is unreliable.
- The k3s cluster is **arm64** (6 nodes). Container images MUST be built
  `--platform linux/arm64 --provenance=false`, else `ImagePullBackOff: no match
  for platform`.

## Git

- **Push over SSH** (`git@github.com:jellebens/...`). HTTPS remotes here have no
  credential helper and will **hang** — switch a remote to SSH before pushing.
- **GitFlow (since 2026-07-02):** work branches off `develop` and merges back
  into `develop` via PR; a user-commanded **release** groups everything into one
  `develop` → `main` PR (version bumped once per release) — merging that PR is
  what deploys (Argo watches `main`). Never commit work directly to `develop`
  or `main`; see AGENTS.md "Branching & Release Flow". Commit/push only when
  asked.

## Secrets

SealedSecrets via kubeseal; controller is **`sealed-secrets` in namespace
`argocd`**:
```sh
kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
  --namespace <ns> --name <secret> --from-file=/dev/stdin
```

## Memory

Durable, cross-session project facts are kept in Claude's per-user memory
(outside the repo, auto-loaded each session) and indexed in `MEMORY.md` there.
Anything that belongs to the repo (conventions, deployment details) should be
written into these in-repo docs instead, so it's version-controlled and
available to every agent. Use the `consolidate-memory` skill to tidy memory.

## Landing zones

- [`landingzones/zeus`](landingzones/zeus/README.md) — Bluetti Apex 300 battery
  optimizer (LIVE, controlling the battery). See its README for wiring, metrics,
  the Grafana dashboard, MQTT, secrets, and the arm64 image build.
- `landingzones/hermes` — see the directory.
