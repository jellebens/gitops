---
name: trello-agents
description: >-
  Spawn subagents to work Trello cards. Reads the TODO list on "My Trello
  board", lets you pick which cards to work, then for each picked card spawns
  an agent that investigates → plans → implements → opens a PR, moving the card
  through the pipeline lists (Investigate → Plan → Doing → Awaiting Validation on
  PR-open → Done on PR-merge; Waiting User Input when blocked). GitHub Flow: one
  card = one `card-<shortId>` branch = one PR into main; agents never touch main.
  Runs cards in parallel (up to 4, each in its own git worktree). Use when the
  user says "work the board", "spawn agents for my Trello tasks", "pick up cards
  from Trello", or names it.
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
  Terminal flow (**GitHub Flow / PR-per-card**): a card lands in **Awaiting
  Validation** once its work is on a pushed `card-<shortId>` branch with an **open
  PR** (summary as the PR body), and only moves to **Done** once that **PR is
  merged** to `main` (the merge is what triggers the Argo deploy). No agent ever
  commits/pushes/merges `main` directly.
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

**One card = one branch = one PR.** Every card is worked on its own
`card-<shortId>` branch, in its **own git worktree** (`isolation: "worktree"`),
and lands as a **pull request into `main`** — never a direct commit/merge to
`main`. GitHub (branch protection + CI) is the gate; the merge is what deploys.
Because each card is an independent PR, there is **no blast radius and no
branch-integration step** — you merge exactly the PRs you approve.

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
independently on GitHub. The old "merge branches into main one at a time" and
"pre-push blast-radius" logic are gone: PRs have no blast radius.)

### 4-merge. Merging the PR is the gate → then Done
Agents open a PR but **must NOT merge it** — merging to `main` triggers the live
Argo deploy. Each worked card sits in **Awaiting Validation** with an open PR.

**"push" (or "merge") comment = authorization to merge that card's PR → Done.**
When the user adds a comment on an Awaiting-Validation card whose text is (or
contains) **push**/**merge**, that's the go-ahead to merge *that card's* PR. On
seeing such a comment:
1. Find the card's PR (from the PR link in its comment, or
   `gh pr list --head card-<shortId>`). Confirm CI is green
   (`gh pr checks <pr>`); if red, **STOP** and surface the failing check.
2. **Merge it** — `gh pr merge <pr> --squash --delete-branch` (for zeus, see the
   image-tag note below). Only that one PR merges — no other card is affected.
3. `move_card` the card to **Done** `698d00d004e1650d4907f897` and `add_comment`
   confirming merged/deployed with the merge commit SHA + PR URL.

Notes:
- **Per-PR, so no blast radius** — merging one card's PR never ships another's.
  This is the whole reason for the PR flow.
- **zeus is two-step:** merging a zeus PR lands the code on `main` but does **not**
  redeploy the app — that still needs an image **version tag** (its own card).
  Say so when merging a zeus PR.
- If a PR won't merge (conflicts / red CI), leave the card in Awaiting Validation,
  add ⚠ Blocked + a comment, and report — don't force it.
- No live Trello webhook, so this fires only when the board is read — see
  "Watching for push comments" in Notes.

A card with an unmerged PR stays in **Awaiting Validation** — that list means
"PR open, reviewable, not yet live." That's exactly the stage for validating a
change (read the diff, let CI run) before it deploys.

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
> 5. **Commit → push branch → open PR.** You are in an isolated git worktree.
>    Create and commit on a branch named `card-{{CARD_SHORT_ID}}` (plain
>    `git commit`, signing disabled) — **never commit to `main`.** Then
>    `git push -u origin card-{{CARD_SHORT_ID}}` (SSH remote), and open a PR into
>    `main` with `gh pr create --base main --head card-{{CARD_SHORT_ID}} --draft
>    --title "#{{CARD_SHORT_ID}} {{CARD_NAME}}" --body "<your full summary + the
>    Trello card URL>"`. **Do NOT merge the PR** — merging deploys and is the
>    human's gate. Report the PR URL.
>
> Constraints: Zeus is LIVE and controlling a real battery — be conservative,
> never break running behavior. If the task is ambiguous, needs a human
> decision, or you'd have to guess at intent, **stop before committing** (leave
> the card wherever it is) and report what's blocking instead of guessing.
>
> **HARD GUARDRAILS (violating these caused real data loss / unauthorized
> deploys — do not cross them):**
> - **Push only your own `card-<shortId>` branch; never `main`.** Do not commit,
>   push, or `gh pr merge` to `main`. Opening a *draft PR* is the finish line.
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
commit-to-`main` mode any more.)

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
  leak onto `main` (real incidents: #61/#65/#66; `git rev-parse --show-toplevel`
  inside the harness worktree returns the main repo). For a card that edits **this
  gitops repo**, instruct the agent to create a sibling worktree with WSL git and
  work only there — `git -C /home/jelle/repos/gitops worktree add
  /home/jelle/repos/gitops-card-<shortId> -b card-<shortId> origin/main` — and to
  **never** edit under `.claude/worktrees/…`. This mirrors the zeus-repo pattern
  (`/home/jelle/repos/zeus-card-<id>`), which had zero incidents. A trivial
  one-liner (e.g. an `image.tag` bump) may instead be done inline by the
  orchestrator on a throwaway branch in the main tree. See AGENTS.md "Known
  Pitfalls" for the mechanism.

### Transition note (2026-07-01)
Cards worked **before** the PR flow (#13, #15, #46) were committed straight onto
`main` (unpushed), not as PRs. Finish those under the old model — a **push**
comment pushes their `main` commit once — or convert them to PRs. All **new**
runs use the PR flow above.

### Watching for push/merge comments
There is no live Trello webhook here, so a **push**/**merge** comment is only acted
on when the board is actually read. It gets picked up when:
- a `trello-agents` run finishes (scan Awaiting Validation as the last step), or
- the user asks to "check the board" / "process push comments", or
- a polling loop is running (e.g. `/loop` every few minutes calling this check).

For a card with an open **PR**, a push/merge comment → `gh pr merge` (step
4-merge). For a legacy card committed on `main` (see Transition note), it → a
one-time `git push`. Scan with `get_cards_by_list_id` → `get_card_comments`,
matching a *user* comment (no `appCreator`) containing `push`/`merge`.
