---
name: trello-agents
description: >-
  Spawn subagents to work Trello cards. Reads the TODO list on "My Trello
  board", lets you pick which cards to work, then for each picked card spawns
  an agent that investigates → plans → implements → opens a PR, moving the card
  through the pipeline lists (Investigate → Plan → Doing → Awaiting Validation on
  PR-open → Done on PR-merge; Waiting User Input when blocked). GitFlow: one
  card = one `card-<shortId>` branch cut from `develop` = one PR into `develop`;
  agents never touch develop or master directly. Releases are user-commanded: all
  merged card work is bundled into ONE develop→master PR (with the version bump);
  merging that PR is what deploys. Runs cards in parallel (up to 4, each in its
  own git worktree). Use when the user says "work the board", "spawn agents for
  my Trello tasks", "pick up cards from Trello", or names it.
---

# Trello → Agents

Turn Trello cards into worked, committed changes. Each selected card is handed
to a fresh subagent that carries it from investigation all the way to a commit,
while this skill keeps the board in sync.

## Board coordinates (this user)

- Board: **"My Trello board"** — `698cfe8456c9783aaf669140`
  (workspace `698cfe827df31516fafe1e2b`)
- Lists (the pipeline, left→right):
  **TODO** `698cff247e95e06b91beec1c` →
  **Investigate** `6a44d2703a0f3c487659ef55` →
  **Plan** `6a44d34451048b039825ac16` →
  **Doing** `698d00cafe6e29f3ff72fdf0` →
  **Awaiting Validation** `6a44f4de25c6ccc80364e600` →
  **Done** `698d00d004e1650d4907f897`.
  **Waiting User Input** `6a44d2832dc9eb8158cb056e` is the off-to-the-side home
  for anything blocked or needing a human decision (not a linear step).
  Terminal flow (**GitFlow / PR-per-card into develop**): a card lands in
  **Awaiting Validation** once its work is on a pushed `card-<shortId>` branch
  (cut from `develop`) with an **open PR into `develop`** (summary as the PR
  body), and moves to **Done** once that **PR is merged into `develop`**.
  Merging to develop INTEGRATES the change but does NOT deploy it — deployment
  happens only at a user-commanded **release** (one bundled develop→master PR;
  see "Release" below). No agent ever commits/pushes/merges `develop` or `master`
  directly.
- Agent slot labels (color-code which agent owns a card):
  **🤖 Agent 1** green `6a44d34fa933973397abc7c0` ·
  **🤖 Agent 2** purple `6a44d35173d2e14e646e2dca` ·
  **🤖 Agent 3** sky `6a44d3537205897e343ebd75` ·
  **🤖 Agent 4** lime `6a44d35538f4ec8fe4d6e9b5` ·
  **⚠ Blocked** red `6a44d3579c2e6b24172bbc3b`
  (Reserve `satisfactory`/orange and `HA`/blue — those mean something else.)

Trello tools are deferred — load them first with
`ToolSearch("select:mcp__trello__get_cards_by_list_id,mcp__trello__get_card,mcp__trello__move_card,mcp__trello__add_comment,mcp__trello__set_active_board")`.
If a call complains the board isn't active, run `set_active_board` on the board
id above.

## Procedure

### 1. Read the board
Fetch TODO cards with `get_cards_by_list_id` (list `698cff247e95e06b91beec1c`,
fields `name,idShort,labels,due,desc`). If TODO is empty, say so and stop.

### 2. Let the user pick
Present the cards as a numbered list (short id + name + one-line desc). Ask
which to work — accept "1,3,5", "all", or names. **Do not** fan out all cards
unprompted. Confirm the selection before spawning anything. Assign each picked
card an agent slot (Agent 1, 2, 3, …) and tell the user the color mapping up
front, e.g. "Agent 1 🟢 → #37, Agent 2 🟣 → #38".

### 3. Work the selected cards

**Who moves the card:** the spawned agent advances it through the *in-progress*
lists (Investigate → Plan → Doing) as it enters each phase, giving you live
visibility. This skill (the orchestrator) owns the *boundaries* — the initial
pickup, the terminal list (Done or Waiting User Input), labels, and comments.
The agent never touches labels, comments, or the terminal lists.

**One card = one branch = one PR into `develop`.** Every card is worked on its
own `card-<shortId>` branch **cut from `develop`**, in its **own git worktree**
(`isolation: "worktree"`), and lands as a **pull request into `develop`** —
never a direct commit/merge to `develop` or `master`. GitHub (branch protection +
CI) is the gate. Merging a card PR integrates it on develop; **nothing deploys
until the user commands a release** (develop→master, see "Release"). Because each
card is an independent PR, there is **no blast radius and no branch-integration
step** — you merge exactly the PRs you approve.

**Parallelism.** Independent cards run concurrently, capped at **4** (one per
agent-slot label 🤖 1–4); >4 picked → run in waves of 4. This is where the
colors earn their keep — several colored 🤖 cards move through
Investigate/Plan/Doing at once, each producing its own PR.

**Dependent cards** (one builds on another's change to the same files) still each
get their own branch+PR, but run them **sequentially** and branch the later one
off the earlier one's branch (or wait for the earlier PR to merge first) — say so
to the user rather than racing two PRs that edit the same lines.

**⚠ PREFLIGHT — protect the user's uncommitted work (mandatory; learned from a
real data-loss incident 2026-07-01).** Before spawning ANY agent, the
orchestrator runs `git -C /home/jelle/repos/gitops status --porcelain` (and the
same for any sibling repo a card will touch). If the tree has **uncommitted
changes** (tracked modifications or staged files):
1. **STOP — do not spawn.** A worktree/branch run can revert or clobber those
   edits, and unstaged changes are **not recoverable** (no git object, no stash).
2. Surface the dirty paths to the user and offer to either (a) commit them on a
   safety branch, (b) `git stash push -u` them under a **named** stash the
   orchestrator will restore afterward, or (c) let the user handle them.
3. Only proceed once the relevant tree is clean (untracked `.claude/` skill/agent
   files are fine to ignore). **The orchestrator** does any stash/commit — never
   an agent, and never a bare `git stash` that a later step could drop.

For each card (in parallel, do steps 1–3 for all cards in the wave, then handle
4/5 as each agent returns; in sequential, do 1–5 fully per card before the next):

1. **Fetch full detail** — `get_card(cardId, includeMarkdown=true)` for the
   complete description (previews are truncated). Note its current label ids.
2. **Pick up: move to Investigate + apply the agent label** — `move_card` to
   Investigate `6a44d2703a0f3c487659ef55` *before* spawning (the board must
   reflect it's in progress, not retroactively), then `update_card_details` with
   `labels = <existing label ids> + <this card's agent slot label id>`.
   ⚠ `labels` **replaces** the whole set — always append to the card's existing
   ids, never send just the agent label alone.
3. **Spawn the agent** — an Agent using the card's **matched specialist profile**
   (`agentType`/`subagent_type`; see "Agent profiles & routing" below — fall back
   to `general-purpose` if nothing matches), always with `isolation: "worktree"`,
   with the prompt in the template below (it self-advances the card and knows to
   commit → push its `card-<shortId>` branch → open a PR). For a wave, issue all
   the Agent calls **in a single message** so they run concurrently.
4. **On success (agent pushed its branch + opened a PR)** — the card is already in
   Doing (the agent moved it). Do all three:
   a. **Post the PR link + a full summary comment** (`add_comment`) — the PR URL
      plus a complete write-up (see "Summary comment" below). If the agent already
      put the summary in the PR body, a short comment with the PR link is enough.
   b. **Remove the agent label** (`update_card_details` with the agent slot id
      filtered out, freeing that color).
   c. **`move_card` to Awaiting Validation** `6a44f4de25c6ccc80364e600` — NOT
      Done. The card reaches Done only when its **PR is merged** (step 4-merge).
5. **On blocked / needs-decision (agent stopped without committing)** —
   `move_card` to **Waiting User Input** `6a44d2832dc9eb8158cb056e`, keep its
   agent label so you can see who got stuck, **add the ⚠ Blocked label**
   (`6a44d3579c2e6b24172bbc3b`), `add_comment` with what the agent found and
   what's blocking, and report it to the user. Do not move it to Done.
(There is no branch-integration step — each card is its own PR, merged
independently on GitHub. The old "merge branches into master one at a time" and
"pre-push blast-radius" logic are gone: PRs have no blast radius.)

### 4-merge. Merging the card PR into develop → then Done
Agents open a PR into `develop` but **must NOT merge it**. Each worked card sits
in **Awaiting Validation** with an open PR.

**"push" (or "merge") comment = authorization to merge that card's PR into
`develop` → Done.** When the user adds a comment on an Awaiting-Validation card
whose text is (or contains) **push**/**merge**, that's the go-ahead to merge
*that card's* PR. On seeing such a comment:
1. Find the card's PR (from the PR link in its comment, or
   `gh pr list --head card-<shortId>`). Confirm CI is green
   (`gh pr checks <pr>`); if red, **STOP** and surface the failing check.
2. **Merge it into develop** — `gh pr merge <pr> --squash --delete-branch`.
   Only that one PR merges — no other card is affected. This does **NOT**
   deploy anything — the change now waits on `develop` for the next release.
3. `move_card` the card to **Done** `698d00d004e1650d4907f897` and `add_comment`
   confirming merged-to-develop (NOT deployed) with the merge commit SHA + PR
   URL, and that it ships with the next release.

Notes:
- **Per-PR, so no blast radius** — merging one card's PR never ships another's.
- If a PR won't merge (conflicts / red CI), leave the card in Awaiting Validation,
  add ⚠ Blocked + a comment, and report — don't force it.
- No live Trello webhook, so this fires only when the board is read — see
  "Watching for push comments" in Notes.

A card with an unmerged PR stays in **Awaiting Validation** — that list means
"PR open, reviewable, not yet integrated." Done means "on develop, ships with
the next release."

### Release (user-commanded; the ONLY path to deploy)
Nothing deploys from card merges. When the user says **"release"** (or
"release zeus", "cut a release"):
1. **zeus repo** (only if its develop has unreleased commits):
   a. On a fresh `release-<version>` branch off `develop`: bump `version` in
      `pyproject.toml` (one bump for the whole batch), commit, push, open a PR
      into `develop`, merge it (this is release mechanics, not card work).
      **Semver rule (owner, 2026-07-03):** if the batch ships a **NEW feature
      or a NEW report/dashboard**, bump the MINOR version by 1 and reset patch
      to 0 (e.g. peak shaving → 0.2.0); if it only **changes existing
      features** (fixes, tweaks, tuning, moved/adjusted panels), bump the
      PATCH by 1. When develop's version was already pre-bumped for the
      feature line, don't bump again — release as-is.
   b. Open **one PR `develop` → `master`** titled `release: v<version>` whose body
      lists every card/commit included. Confirm CI green. Merge with
      `gh pr merge --merge` (**merge commit, NOT squash** — keeps develop and
      main from diverging).
   c. **Tag the merge commit on `master`** — `git tag v<version> && git push
      origin v<version>`. Zeus CI builds + pushes the arm64 image
      `jellebens/zeus:<version>` automatically on the `v*` tag (this untagged
      step is exactly what left 0.1.54 unbuilt on 2026-07-02). Wait for the CI
      image job to go green (`gh run watch` / `gh run list`) before step 2;
      local `docker buildx build --platform linux/arm64 --provenance=false`
      is the fallback if CI is unavailable.
2. **gitops repo**: on `develop`, bump `landingzones/zeus/values.yaml`
   `image.tag` to `<version>` (skip if no zeus release), then open **one PR
   `develop` → `master`** bundling the tag bump + every merged gitops card.
   Confirm CI green, merge with a **merge commit**. **Merging this PR is the
   deploy** — Argo reconciles from gitops `master` (sync or let auto-sync run).
3. Verify the rollout (pod on the new image, first cycle Optimal, no errors)
   and report what shipped: version, cards included, verification output.
4. **Update the changelog.** After the tag(s) are pushed and the rollout is
   verified, invoke the **mnemosyne** agent (`Agent` with
   `subagent_type: mnemosyne`) — it reconciles `jupiter/CHANGELOG.md` against the
   new `v*` tags and opens a draft PR into `develop`. Do this for every release,
   jupiter and/or zeus; if no new tag was cut (gitops-only deploy), skip it.
   Merge that PR with the next batch — it needs no separate release (docs only).
Order matters: zeus first (image must exist before the tag bump deploys), then
gitops. If only gitops cards are pending, step 2 alone is the release (and
step 4 is skipped — no new app tag).

**Tag every jupiter/zeus `master` merge (owner, 2026-07-14).** Every
`develop` → `master` release PR gets a `v<version>` tag — including a
docs-only release — so `master` is fully traceable and no version is left
untagged (the state that let CHANGELOG.md sit on `master` unversioned). The
jupiter CI `tag-scope` job diffs the new tag against the previous one and, when
the change is docs-only (`*.md`, `docs/`, `CHANGELOG.md`, `LICENSE`), sets
`docs_only=true` so the arm64 `image` build is skipped — the tag still exists,
CI is green, no images rebuild. A code change (anything else, incl. `ci.yml`)
builds normally. So: bump the version + tag for docs-only releases too; don't
wait on an image job that intentionally won't run.

## Agent prompt template

Fill in `{{CARD_NAME}}`, `{{CARD_SHORT_ID}}`, `{{CARD_DESC}}`, `{{CARD_ID}}`:

> You are working a single task from a Trello board in the gitops repo at
> `/home/jelle/repos/gitops` (WSL ubuntu). Read `AGENTS.md` and `CLAUDE.md`
> first — follow every repo convention (Argo CD + Helm only; **no Flux/
> Kustomize**; arm64 image builds `--platform linux/arm64 --provenance=false`;
> run git/helm/kubectl/argocd through WSL).
>
> **Card #{{CARD_SHORT_ID}}: {{CARD_NAME}}** (card id `{{CARD_ID}}`)
>
> {{CARD_DESC}}
>
> **Keep the board in sync as you go.** The Trello `move_card` tool is deferred —
> load it once with `ToolSearch("select:mcp__trello__move_card")`. Move THIS card
> (id `{{CARD_ID}}`) into each list the moment you enter that phase:
> - entering **Plan** → move to list `6a44d34451048b039825ac16`
> - entering **Implement** → move to list `698d00cafe6e29f3ff72fdf0` (Doing)
> (You start already in the Investigate list. Do NOT move it to Done or Waiting
> User Input, and do NOT touch labels or comments — the orchestrator owns those.)
>
> Do the full pipeline for THIS card only:
> 1. **Investigate** — read the relevant files/manifests; confirm the real
>    cause/scope. State what you found.
> 2. **Plan** (move card to Plan) — a concrete step list of the exact edits.
> 3. **Implement** (move card to Doing) — make the changes. Match surrounding
>    style. If it involves a container image, build it arm64 as above.
> 4. **Verify** — lint/`helm template`/`kubectl --dry-run` or whatever proves
>    the change is valid. Report the output.
> 5. **Commit → push branch → open PR into `develop`.** You are in an isolated
>    git worktree. Create and commit on a branch named `card-{{CARD_SHORT_ID}}`
>    **cut from `origin/develop`** (plain `git commit`, signing disabled) —
>    **never commit to `develop` or `master`.** Then
>    `git push -u origin card-{{CARD_SHORT_ID}}` (SSH remote), and open a PR into
>    `develop` with `gh pr create --base develop --head card-{{CARD_SHORT_ID}}
>    --draft --title "#{{CARD_SHORT_ID}} {{CARD_NAME}}" --body "<your full
>    summary + the Trello card URL>"`. **Do NOT merge the PR** — merging is the
>    human's gate, and deployment only happens at a user-commanded release
>    (develop→master). Do NOT bump any version — versions are bumped once per
>    release, not per card. Report the PR URL.
>
> Constraints: Zeus is LIVE and controlling a real battery — be conservative,
> never break running behavior. If the task is ambiguous, needs a human
> decision, or you'd have to guess at intent, **stop before committing** (leave
> the card wherever it is) and report what's blocking instead of guessing.
>
> **HARD GUARDRAILS (violating these caused real data loss / unauthorized
> deploys — do not cross them):**
> - **Push only your own `card-<shortId>` branch; never `master`.** Do not commit,
>   push, or `gh pr merge` to `master`. Opening a *draft PR* is the finish line.
> - **Stay inside your own worktree.** Never run tree-mutating git (`stash`,
>   `checkout`/`restore`, `reset`, `clean`, `add`/`rm` of paths you didn't
>   change) against another tree. If you find pre-existing uncommitted changes
>   you didn't make, **do not stash/revert/commit them** — report and stop.
> - **No live-prod mutations.** No `kubectl exec`/`apply`/`delete`/`scale`,
>   `argocd app sync`, or writes to live InfluxDB/HA/the cluster/databases.
>   Dry-run/read-only verification only (`--dry-run`, `helm template`,
>   `/api/ds/query` reads). A live run is a separate human-gated step — describe
>   it in your summary, don't do it.
> - Scope changes to THIS card. Don't opportunistically commit unrelated
>   working-tree changes you didn't author.
>
> Return, concisely: what you found, what you changed (files), verification
> output, the branch name, the commit SHA, and the **PR URL** (or why you stopped
> without committing).

(All runs are worktree-isolated on branch `card-<shortId>`; there is no
commit-to-`master` mode any more.)

## Agent profiles & routing
Specialist agent types live in `.claude/agents/`. Pass the matched one as the
Agent's `subagent_type`/`agentType`. Route by the primary repo/files the card
will edit (from its description/summary), not just its topic label:

| Profile (`subagent_type`) | Route when the card… |
|---|---|
| `hestia` (HA) | changes the `home-assitant` repo — packages/templates/recorder/zwave/HA-native config (topic label 🔵 HA). |
| `argus` (Grafana) | edits dashboard JSON (`landingzones/*/dashboards/*.json`), InfluxDB/Flux, kiosk tiles. **These are often labeled `zeus` — route by file path, not the label.** |
| `hephaestus` (zeus app) | changes the `zeus` Python app (prices/forecaster/optimizer/controller/metrics/tests); label 🟡 zeus **and not a dashboard**. |
| `atlas` (infra) | touches Cilium/NetworkPolicies, CoreDNS/DNS, k3s, Argo, `platform/` (usually the unlabeled infra/DNS cards). |
| `general-purpose` | fallback: card spans repos or matches nothing cleanly. |

Tie-breaker: a dashboard change under `landingzones/zeus/` is **`argus`**, not
`hephaestus`. If a card genuinely spans domains, pick the profile for the bulk of
the work (or suggest splitting it into per-domain cards). New profiles load at
session start.

## Summary comment (posted when the card enters Awaiting Validation)
A complete record of what was done — someone reading only this comment should
understand the whole change. Include, in this order:
- **What & why** — the problem/goal and the root cause or approach taken.
- **Changes** — the files touched and what changed in each (bullet list).
- **Verification** — commands run and their result (`helm template`, `jq`,
  `kubectl --dry-run`, tests, etc.).
- **PR** — the PR URL + branch, and that it is **open, not yet merged** (so it's
  clear why the card is in Awaiting Validation, not Done).
- **Validation notes / risks** — anything the human should check in review before
  merging, and any follow-ups spun off.
Keep it readable (headings/bullets), not a wall of text.

## Notes
- If the user asked to work cards from a different list (e.g. Doing), swap the
  source list id but keep the same flow.
- Concurrency is capped at 4 by the agent-slot labels (🤖 1–4). More than 4
  picked cards → run in waves of 4, reusing a color only after its card's PR is
  merged and its label was removed.
- Every card is worktree-isolated on its own branch — for dependent cards (later
  builds on earlier), branch the later PR off the earlier one or wait for it to
  merge; don't race two PRs editing the same lines.
- **gitops-repo cards — use a *sibling WSL* worktree, not the harness one.** The
  Agent tool's `isolation: "worktree"` creates the worktree under
  `.claude/worktrees/…` with a Windows UNC gitdir WSL git can't resolve, so from
  WSL it is indistinguishable from the **main** tree and edits/commits silently
  leak onto `master` (real incidents: #61/#65/#66; `git rev-parse --show-toplevel`
  inside the harness worktree returns the main repo). For a card that edits **this
  gitops repo**, instruct the agent to create a sibling worktree with WSL git and
  work only there — `git -C /home/jelle/repos/gitops worktree add
  /home/jelle/repos/gitops-card-<shortId> -b card-<shortId> origin/develop` — and to
  **never** edit under `.claude/worktrees/…`. This mirrors the zeus-repo pattern
  (`/home/jelle/repos/zeus-card-<id>`), which had zero incidents. A trivial
  one-liner (e.g. an `image.tag` bump) may instead be done inline by the
  orchestrator on a throwaway branch in the main tree. See AGENTS.md "Known
  Pitfalls" for the mechanism.

### Transition notes
- **2026-07-02 — GitFlow.** The user switched the flow from GitHub Flow
  (card PR → main, merge = deploy) to **GitFlow**: card PRs target `develop`;
  a user-commanded **release** bundles everything on develop into ONE
  develop→master PR (with the single version bump); merging THAT deploys. The
  `develop` branches were cut from the trunk on 2026-07-02. Any pre-existing open
  card PR that still targets `master` should be retargeted to `develop`
  (`gh pr edit <pr> --base develop`) before merging.
- **2026-07-01.** Cards worked before the PR flow (#13, #15, #46) were committed
  straight onto `master` (unpushed). Finish those under the old model — a **push**
  comment pushes their `master` commit once — or convert them to PRs.

### Watching for push/merge comments
There is no live Trello webhook here, so a **push**/**merge** comment is only acted
on when the board is actually read. It gets picked up when:
- a `trello-agents` run finishes (scan Awaiting Validation as the last step), or
- the user asks to "check the board" / "process push comments", or
- a polling loop is running (e.g. `/loop` every few minutes calling this check).

For a card with an open **PR**, a push/merge comment → `gh pr merge` (step
4-merge). For a legacy card committed on `master` (see Transition note), it → a
one-time `git push`. Scan with `get_cards_by_list_id` → `get_card_comments`,
matching a *user* comment (no `appCreator`) containing `push`/`merge`.
