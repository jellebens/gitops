# Hermes landing zone — Cortana

A single [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(`nousresearch/hermes-agent`, currently `v0.16.0`) running on the cluster as
**Cortana**, a voice-first personal assistant on Discord. Cortana delegates
specialised work to short-lived subagents: **Calliope** (writes articles/blog
posts and commits them to a git repo), **Aetos** (a read-only energy/battery
analyst that reports on the Zeus optimizer), and **Hebe** (a dependency-update
watcher that opens draft bump PRs against this gitops repo).

Namespace: `hermes`. Deployed by Argo CD (`applications/templates/hermes`,
sync-wave 30) from this chart, with values layered as:

```
landingzones/hermes/values.yaml          # chart defaults (Cortana's full config)
.config/shared/values.yaml               # shared (repos, etc.)
.config/<env>/values.yaml                # environment selector
.config/<env>/hermes.yaml                # env/secret overrides (Discord, git, backup)
```

## Architecture

```
cortana ── the single agent (Deployment "hermes")
  • Discord bot (channels #cortana + #bots), voice (TTS/STT)
  • MS365 mail/calendar via the ms365-mcp MCP server
  • memory + user profile (SQLite on a local-path PVC)
  • web dashboard at https://hermes.lab.local
  • delegation toolset enabled
        ├─ delegate_task ─▶ Calliope (ephemeral writer subagent)
        │                     toolsets: terminal, file, web, search, memory
        │                     clones the blog repo on the PVC, drafts Markdown,
        │                     commits and pushes to a drafts/<slug> branch
        ├─ delegate_task ─▶ Aetos (ephemeral energy/battery analyst)
        │                     toolsets: terminal, web, search, memory
        │                     queries the Zeus optimizer read-only (Prometheus +
        │                     zeus-metrics) and reports charge/mode/price/savings
        └─ delegate_task ─▶ Hebe (ephemeral dependency-update watcher)
                              toolsets: terminal, web, search, memory (+ git)
                              enumerates pinned versions in this gitops repo,
                              opens one DRAFT bump PR per update into develop
                              (arm64-only; never merges)
  nightly CronJob ── sqlite3 .backup ──▶ SMB share (smb-cortana StorageClass)
```

There is **one** agent. Earlier there were two (a default `hermes` bot + an
`extraAgents.cortana` deployment); Cortana was promoted into the main deployment
(adopting her existing PVC `hermes-cortana-state` in place) and the default bot
was retired. The `extraAgents` mechanism in
[templates/extra-agents.yaml](templates/extra-agents.yaml) remains for adding
further standalone agents later.

## The writer subagent

The writer is **not** a separate deployment. It is a native Hermes
`delegate_task` child spawned by Cortana inside the same pod (flat delegation:
`config.delegation.max_spawn_depth: 1`). v0.16.0 has no named agent profiles
(upstream issue #9459), so its **workflow** lives in Cortana's
`config.agent.system_prompt` and its **writing persona** is a separate SOUL file
(`.Values.writer.soul`) rendered into the `hermes-writer-soul` ConfigMap and
mounted read-only at `.Values.writer.soulPath` (`/opt/writer/SOUL.md`). Cortana
instructs the writer to read and embody it. Edit `writer.soul` to tune the voice
without touching delegation logic.

Git wiring (`.Values.git`, enabled in `.config/lab/hermes.yaml`):

| Setting | Value |
|---|---|
| Repo | `git@github.com:jellebens/blog.git` |
| Clone path (on PVC) | `/opt/data/workspace/content` |
| Posts subdir | `content/posts` |
| Branch | `master` |
| Auth | `ed25519` deploy key, sealed into secret `hermes-writer-git-ssh` |

The `seed-config` init container installs the key to `/opt/data/.ssh`
(0600), pins GitHub's host key, and clones/pulls the repo — **best-effort**, so
a git failure never blocks Cortana from starting. The gateway container carries
`GIT_SSH_COMMAND` so the writer's `git push` authenticates with the deploy key.

To rotate the deploy key:

```sh
ssh-keygen -t ed25519 -N "" -C "hermes-writer deploy key" -f /tmp/hwk
kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
  --namespace hermes --name hermes-writer-git-ssh --from-file=/tmp/hwk
# -> paste into .config/lab/hermes.yaml git.ssh.sealedSecret.encryptedKey
# add /tmp/hwk.pub to the repo as a WRITE deploy key, then: shred -u /tmp/hwk*
```

## The Aetos subagent

Same delegation pattern as Calliope. **Aetos** is a read-only **energy/battery
analyst** for the [Zeus optimizer](../zeus/README.md). Its persona + query
knowledge live in `.Values.aetos.soul` → `hermes-aetos-soul` ConfigMap → mounted
at `.Values.aetos.soulPath` (`/opt/aetos/SOUL.md`); Cortana routes any
battery/energy/price/savings question to it (`delegate_task`, toolsets
`terminal, web, search, memory`).

It talks to Zeus over read-only HTTP from the pod (no creds, in-cluster):

| Channel | Endpoint |
|---|---|
| Instant state | `http://zeus-metrics.zeus.svc.cluster.local:9000/metrics` |
| History / PromQL | `http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090/api/v1/query` |

**Aetos never controls the battery** — Zeus is the sole controller, and two
controllers fighting it is harmful. Aetos only reads `zeus_*` metrics (SoC, mode,
prices, savings, forecast) and reports.

## The Hebe subagent

Same delegation pattern as Calliope/Aetos. **Hebe** (Greek goddess of youth and
renewal) is a **dependency-update watcher** for **this gitops repo**. Persona +
update knowledge live in `.Values.hebe.soul` → `hermes-hebe-soul` ConfigMap →
mounted at `.Values.hebe.soulPath` (`/opt/hebe/SOUL.md`); Cortana routes "check
for updates / bump X" to her (`delegate_task`, toolsets
`terminal, web, search, memory`).

Hebe enumerates the versions this repo pins — container `image.tag`
(`landingzones/*`, `platform/*`), Helm chart `dependencies[].version`, and Argo
`Application.targetRevision`/platform component versions — finds newer eligible
**stable** versions (registry tag APIs, `helm search repo --versions`, GitHub
releases), and opens **one draft PR per bump** on an `update-<component>-<ver>`
branch **into `develop`** (GitFlow; `master` deploys). She **never merges** and
never pushes to `develop`/`master`. Two hard rules:

- **arm64-or-it-doesn't-ship** — she never proposes a container tag without a
  confirmed `linux/arm64` manifest (wrong arch = `ImagePullBackOff`), and cites
  the arch evidence in the PR body.
- **zeus is two-step** — she never proposes a zeus `image.tag` that has not been
  built and published as an arm64 image (the image is built from the zeus repo
  on release, then bumped here).

She is **read-only against the cluster** — her only writes are the git branch and
draft PR.

### Hebe's git access (second repo + own deploy key)

The writer's `.Values.git` block wires exactly one repo (the blog). Hebe needs a
**second** repo (this gitops one) with its **own write deploy key**, so her
wiring lives in a separate `.Values.hebe.git` block:

| Setting | Value |
|---|---|
| Repo | `git@github.com:jellebens/gitops.git` |
| Clone path (on PVC) | `/opt/data/workspace/gitops` |
| Base/target branch | `develop` |
| Auth | `ed25519` deploy key, sealed into secret `hermes-hebe-git-ssh` |

The `seed-config` init container installs her key at a **distinct** path
(`/opt/data/.ssh/id_ed25519_hebe`), merges her host key into `known_hosts`, and
pins the key to her clone via a per-repo `core.sshCommand` — so it never clashes
with the writer's global `GIT_SSH_COMMAND`. Setup is best-effort; a git failure
never blocks Cortana from starting.

`.Values.hebe.git.enabled` defaults to **false**. To turn Hebe on, an owner must
(1) generate an ed25519 keypair, (2) `kubeseal` the private half into
`hermes-hebe-git-ssh` and paste it into `.config/lab/hermes.yaml`
`hebe.git.ssh.sealedSecret.encryptedKey`, (3) **add the public key to
`jellebens/gitops` as a WRITE deploy key** (owner action — not done by this
chart), and (4) set `hebe.git.enabled: true`:

```sh
ssh-keygen -t ed25519 -N "" -C "hermes-hebe deploy key" -f /tmp/hebek
kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
  --namespace hermes --name hermes-hebe-git-ssh --from-file=/tmp/hebek
# -> paste into .config/lab/hermes.yaml hebe.git.ssh.sealedSecret.encryptedKey
# add /tmp/hebek.pub to jellebens/gitops as a WRITE deploy key, then: shred -u /tmp/hebek*
```

PR creation: Hebe uses the in-pod `gh` CLI (`gh pr create --draft`) if a token is
present; otherwise she pushes the branch and reports a ready-to-paste PR body.
(`gh pr edit` is broken in this environment — use `gh api PATCH` for bodies.)
Trigger is **on-demand** via Cortana `delegate_task`; a nightly CronJob (cf. the
sqlite backup CronJob) is a possible future alternative.

## Storage & backups

State (`state.db`, `kanban.db`, memory, profile, MS365 token) is **SQLite in WAL
mode**, which cannot live on a network filesystem — so the live PVC stays on
`local-path` (node-pinned). Durability comes from a nightly CronJob
([templates/backup-cronjob.yaml](templates/backup-cronjob.yaml)) that uses the
SQLite **online `.backup` API** plus a file copy of the rest, writing to an
SMB-backed PVC on the `smb-cortana` StorageClass (`Retain`). The job co-locates
with the agent pod via pod-affinity (to attach the RWO local-path volume).

Restore: untar/copy a dated dir from the `hermes-backup` PVC back into
`hermes-cortana-state` while the agent is scaled to 0.

## Secrets (all SealedSecrets, controller `sealed-secrets` in `argocd`)

| Secret | Purpose |
|---|---|
| `hermes-openai-api-key` | OpenAI API key (model + TTS/STT) |
| `hermes-cortana-discord-token` | Cortana's Discord bot token |
| `hermes-writer-git-ssh` | writer's git deploy key (blog repo) |
| `hermes-hebe-git-ssh` | Hebe's git deploy key (gitops repo, write) — only when `hebe.git.enabled` |

## Common operations

```sh
# logs / shell (run via WSL: wsl -d ubuntu -- bash -lc '...')
kubectl -n hermes logs deploy/hermes -c gateway -f
kubectl -n hermes exec -it deploy/hermes -c gateway -- bash

# dashboard
#   https://hermes.lab.local

# effective config inside the pod
kubectl -n hermes exec deploy/hermes -c gateway -- hermes config show

# trigger a backup now
kubectl -n hermes create job --from=cronjob/hermes-backup hermes-backup-manual
```

## Notable config

- Model: `gpt-5.4-mini` via `openai-api` (`config.model`).
- Discord: `require_mention: false`, allow-listed channels, voice auto-TTS on.
- MS365: `ms365-mcp` MCP server scoped to mail + calendar.
- Toolsets: `hermes-cli`, `mcp`, `delegation`.
