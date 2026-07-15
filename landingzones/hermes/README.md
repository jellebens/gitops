# Hermes landing zone — Cortana

A single [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(`nousresearch/hermes-agent`, currently `v0.16.0`) running on the cluster as
**Cortana**, a voice-first personal assistant on Discord. Cortana delegates
specialised work to short-lived subagents: **Calliope** (writes articles/blog
posts and commits them to a git repo), **Aetos** (a read-only energy/battery
analyst that reports on the Zeus optimizer), **Hebe** (a dependency-update
watcher that opens draft bump PRs against this gitops repo), **Plutus** (a
read-only AI-subscription cost tracker that posts a daily token/spend digest to
Discord), and **Cerberus** (a READ-ONLY Prometheus watchdog that files triaged
Trello cards for cluster/battery problems and posts a daily 18:00 owner digest
to Discord).

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
        ├─ delegate_task ─▶ Hebe (ephemeral dependency-update watcher)
        │                     toolsets: terminal, web, search, memory (+ git)
        │                     enumerates pinned versions in this gitops repo,
        │                     opens one DRAFT bump PR per update into develop
        │                     (arm64-only; never merges)
        ├─ delegate_task ─▶ Plutus (ephemeral AI-cost tracker, daily)
        │                     toolsets: terminal, web, search, memory
        │                     GETs each AI provider's usage/cost API read-only
        │                     (Anthropic Admin + OpenAI org usage), posts a daily
        │                     spend digest to Discord (never mutates anything)
        └─ delegate_task ─▶ Cerberus (READ-ONLY Prometheus watchdog)
                              toolsets: terminal, web, search, memory
                              two INDEPENDENT schedules Cortana enforces:
                                • every 30 min — poll ALERTS, dedup, file ONE
                                  triaged Trello card per new firing problem
                                • daily 18:00 Europe/Brussels — compile the owner
                                  digest; Cortana posts it to Discord
                              never mutates the cluster or the battery
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

## The Plutus subagent

Same delegation pattern as Calliope/Aetos/Hebe. **Plutus** (Ploutos, the Greek
god of wealth) is a **read-only AI-subscription cost tracker**. Once a day
Cortana delegates to him; he pulls yesterday's token usage and spend from each
configured AI provider's **official usage/cost API** and hands Cortana a compact
money digest that she posts to her **Discord** home channel. Persona + operating
manual live in `.Values.plutus.soul` → `hermes-plutus-soul` ConfigMap → mounted
at `.Values.plutus.soulPath` (`/opt/plutus/SOUL.md`). He is **strictly
READ-ONLY** — GET requests to documented cost APIs only; he never changes a plan,
buys credits, rotates a key, or mutates billing/cluster/git/battery, and he
**never invents a number** (an unconfigured provider is reported as such).

### Data sources (documented provider APIs — no dashboard scraping)

| Provider | Endpoints (GET) | Credential |
|---|---|---|
| Anthropic (Claude) | `…/v1/organizations/cost_report` (USD) · `…/v1/organizations/usage_report/messages` (tokens), host `api.anthropic.com` | **Admin API key** `sk-ant-admin…` in the `x-api-key` header + `anthropic-version: 2023-06-01` |
| OpenAI | `…/v1/organization/costs` (USD) · `…/v1/organization/usage/completions` (tokens), host `api.openai.com` | **Admin key** `sk-admin…` as `Authorization: Bearer` |

Both credentials are **admin-scoped and distinct from the normal inference key** —
a plain `sk-ant-api…` key or the project OpenAI key hermes already holds **cannot**
read the org usage/cost report. The Anthropic admin key is created by an org admin
in the Anthropic Console; the OpenAI admin key by an org owner in the org
settings. Egress is to `api.anthropic.com` / `api.openai.com` over the pod's open
egress (the CNP is ingress-only; both hosts are pre-listed in its egress comment
for a future allow-list).

### Turning Plutus on (owner action — gated + inert by default)

Both providers ship **disabled** (`plutus.<provider>.enabled: false`, empty
sealed key). The SOUL, the schedule, the ConfigMap and the delegation block all
render regardless, so Plutus exists as soon as this merges — but with no admin
key he will report every provider as "unconfigured" and post an all-quiet digest.
To activate a provider the owner must (1) mint the **admin** key in that
provider's console, (2) `kubeseal` it, (3) paste the sealed value into
`.config/lab/hermes.yaml`, and (4) flip that provider's `enabled: true`:

```sh
# Anthropic (repeat with the OpenAI admin key + hermes-plutus-openai-admin)
printf '%s' 'sk-ant-admin-...' | kubeseal --raw \
  --controller-name sealed-secrets --controller-namespace argocd \
  --namespace hermes --name hermes-plutus-anthropic-admin --from-file=/dev/stdin
# -> paste into .config/lab/hermes.yaml:
#      plutus.anthropic.enabled: true
#      plutus.anthropic.sealedSecret.encryptedAdminKey: <sealed value>
```

The env var (`PLUTUS_ANTHROPIC_ADMIN_KEY` / `PLUTUS_OPENAI_ADMIN_KEY`) and the
SealedSecret only render when that provider is both `enabled` and has a non-empty
sealed key, so a half-configured provider never produces a broken Secret ref.

**Schedule / delivery:** one daily delegation at `plutus.digest.schedule`
(`0 8 * * *`, Europe/Brussels), delivery channel Discord — Cortana enforces it in
her `system_prompt` (mirrors the Cerberus digest pattern). Kept off Cerberus's
18:00 slot so the two daily posts don't collide.

## The Cerberus subagent (watchdog + daily digest)

Same delegation pattern as Aetos/Hebe. **Cerberus** (the three-headed hound
guarding the gate) is a **READ-ONLY Prometheus watchdog**. Card **#187** moved
it from an owner-machine Claude Code scheduled task into hermes as a native
`delegate_task` subagent — so its prompt/config is version-controlled here, like
the other subagents. Persona + operating summary live in `.Values.cerberus.soul`
→ `hermes-cerberus-soul` ConfigMap → mounted read-only at `.Values.cerberus.soulPath`
(`/opt/cerberus/SOUL.md`). Its **full routing table** (exact PromQL, severity
map, per-alert triage, dedup key, card template, topic/list IDs) stays version-
controlled in [`platform/cerberus/README.md`](../../platform/cerberus/README.md) —
that is the authoritative operating manual; the SOUL file points at it.

Cortana runs Cerberus on **two independent schedules** (declared in her
`system_prompt`; canonical values in `.Values.cerberus.watchdog.schedule` /
`.Values.cerberus.digest.schedule`) so the digest can never delay the watchdog:

| Schedule | Cadence | What it does |
|---|---|---|
| Watchdog poll | every 30 min (`*/30 * * * *`) | poll `ALERTS` (+ raw safety-net queries), dedup on the `cerberus-key:` marker, file ONE triaged Trello card in TODO per NEW firing problem |
| Owner digest | daily 18:00 `Europe/Brussels` (`0 18 * * *`) | compile a ~15-line overview (fleet health, savings + parity + soak clean days, spike-responder observe stats, 24h alerts/cards, anything awaiting an owner click); Cortana posts it to her **Discord** home channel |

**Delivery channel = Discord** (the card left this open at investigate): hermes
already has Discord egress and a home channel, so Cortana posting the digest is
the least-moving-parts choice; a pinned-card Trello comment was the fallback.

**Trust boundary (unchanged):** READ-ONLY diagnosis + Trello card creation ONLY.
Cerberus never mutates the cluster or the battery — no `kubectl apply/…`, no
argocd, no git, no Alertmanager/rule edits, no MQTT/HA writes; proposed fixes go
in the card body for a human/specialist.

**How it reaches things (open pod egress, no new MCP):**

| Channel | Endpoint |
|---|---|
| Prometheus (alerts/history) | `http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090/api/v1/query` |
| Trello (file/dedup cards) | `https://api.trello.com/1` via REST, authed with `CERBERUS_TRELLO_API_KEY` + `CERBERUS_TRELLO_TOKEN` |

The Trello creds are a **SealedSecret** `hermes-cerberus-trello` (`api-key` +
`token`), env-injected into the gateway container. It stays disabled until the
sealed halves are provided in the environment overlay
(`.config/lab/hermes.yaml`); absent creds → Cerberus reports "Trello
unconfigured" and stays passive (still safe, just no card).

**Cutover:** when this ships, **retire the old owner-machine cerberus scheduled
task** so the two runners don't double-file (dedup would catch duplicates, but
the standalone runner is superseded — turn it off at deploy).

To provision the Trello creds:

```sh
# Trello API key + a token for the board (owner obtains from trello.com/app-key)
printf '%s' "<api-key>" | kubeseal --raw --controller-name sealed-secrets \
  --controller-namespace argocd --namespace hermes --name hermes-cerberus-trello \
  --from-file=/dev/stdin        # -> cerberus.trello.sealedSecret.encryptedApiKey
printf '%s' "<token>"   | kubeseal --raw --controller-name sealed-secrets \
  --controller-namespace argocd --namespace hermes --name hermes-cerberus-trello \
  --from-file=/dev/stdin        # -> cerberus.trello.sealedSecret.encryptedToken
# then set cerberus.trello.enabled: true in .config/lab/hermes.yaml
```

## Storage & backups

State (`state.db`, `kanban.db`, memory, profile, MS365 token) is **SQLite in WAL
mode**, which cannot live on a network filesystem — so the live PVC stays on
`local-path` (node-pinned). Durability comes from a nightly CronJob
([templates/backup-cronjob.yaml](templates/backup-cronjob.yaml)) that uses the
SQLite **online `.backup` API** plus a file copy of the rest, writing to an
SMB-backed PVC on the `smb-cortana` StorageClass (`Retain`). The job co-locates
with the agent pod via pod-affinity (to attach the RWO local-path volume).

**What is backed up, where:** `backup.databases` (`state.db`, `kanban.db`, via
the online `.backup` API) plus `backup.extraPaths` (`config.yaml`, `auth.json`,
`SOUL.md`, `.env`, `.ms-365-mcp-server`, `cron`), staged on local disk and then
bulk-copied to the `hermes-backup` PVC → SMB share
`//nas001.lab.local/cortana-backup` (subdir `pvc-<uid>/<YYYYMMDD-HHMMSS>/`),
nightly at 03:17 (`backup.schedule`), 14-day retention on the share.

**Guardrails** (added after the 2026-06/07 stuck-job incident, #175): the Job
carries `activeDeadlineSeconds` (default 1800s — a normal run takes ~30s) so a
wedged run (e.g. unmountable SMB volume) is killed instead of blocking every
later run via `concurrencyPolicy: Forbid`; `startingDeadlineSeconds` (3600s)
bounds late starts; `ttlSecondsAfterFinished` (3d) GCs old jobs. Freshness is
alerted directly by **`HermesBackupNotRun`**
([templates/backup-prometheusrule.yaml](templates/backup-prometheusrule.yaml)):
fires when `kube_cronjob_status_last_successful_time` is older than
`backup.prometheusRule.maxAgeSeconds` (default 48h = 2× the schedule) or absent.

**Verify backups are healthy:**

```sh
# last successful run (should be < 24h ago)
kubectl -n hermes get cronjob hermes-backup -o jsonpath='{.status.lastSuccessfulTime}'
kubectl -n hermes get jobs
# spot-check the share content (from any SMB client, or the NAS)
#   //nas001.lab.local/cortana-backup/pvc-<uid>/<date>/state.db
# trigger a run now and watch it complete (~30s)
kubectl -n hermes create job --from=cronjob/hermes-backup hermes-backup-manual
kubectl -n hermes get pods -l app.kubernetes.io/name=hermes-backup -w
```

**Runbook — backup stuck / `HermesBackupNotRun` firing:**

1. `kubectl -n hermes describe pod <backup-pod>` — look at the last `Events`.
2. `FailedMount ... could not connect to <IP>` against the SMB share means the
   PV is pinning a stale NAS address. Dynamically provisioned SMB PVs bake the
   `source` into their immutable `volumeHandle` at provision time — fixing the
   StorageClass (done 2026-06-28: `//nas001.lab.local/...` instead of a DHCP
   IP) does **not** heal existing PVs. Recreate the PV:

   ```sh
   kubectl -n hermes delete job <stuck-job>          # unblocks Forbid
   kubectl -n hermes delete pvc hermes-backup        # Argo recreates it from this chart
   kubectl delete pv <old-pv>                        # reclaimPolicy Retain: share data is untouched
   # csi-smb provisions a fresh PV from the (name-based) smb-cortana class;
   # older backups stay on the share under the previous pvc-<uid> subdir.
   kubectl -n hermes create job --from=cronjob/hermes-backup hermes-backup-manual
   ```

3. Any other wedge: the job self-terminates at `activeDeadlineSeconds` and the
   next nightly window runs; fix the cause before then if the alert persists.

**Restore:** scale the agent to 0, copy a dated dir from the `hermes-backup`
PVC (or straight from the share) back into `hermes-cortana-state`, scale up.

## Secrets (all SealedSecrets, controller `sealed-secrets` in `argocd`)

| Secret | Purpose |
|---|---|
| `hermes-openai-api-key` | OpenAI API key (model + TTS/STT) |
| `hermes-cortana-discord-token` | Cortana's Discord bot token |
| `hermes-writer-git-ssh` | writer's git deploy key (blog repo) |
| `hermes-hebe-git-ssh` | Hebe's git deploy key (gitops repo, write) — only when `hebe.git.enabled` |
| `hermes-plutus-anthropic-admin` | Anthropic **Admin** API key for Plutus (read-only usage/cost) — only when `plutus.anthropic.enabled` |
| `hermes-plutus-openai-admin` | OpenAI **Admin** key for Plutus (read-only org usage/costs) — only when `plutus.openai.enabled` |
| `hermes-cerberus-trello` | Cerberus's Trello API key + token (`api-key`, `token`) — only when `cerberus.trello.enabled` |

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
