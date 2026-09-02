# ADR-0001: Cortana's chat model — gpt-5.6-terra (upgrade from gpt-5.4-mini)

- **Status:** Accepted (2026-09-03). First ADR in the gitops repo; the jupiter
  repo keeps its own ADR series (`jupiter/docs/adr/`, through ADR-0025) — this
  series covers cross-cutting cluster/landing-zone decisions that live in
  gitops, starting with the hermes/Cortana stack.
- **Decided:** 2026-09-03 (owner, card #276). Sources: as-built
  `landingzones/hermes/values.yaml` (`config.model`), hermes README "Notable
  config", OpenAI GPT-5.6 launch material and September 2026 API pricing.
- **Deciders:** Jelle (owner), with Claude
- **Tags:** hermes, cortana, openai, model-selection, cost

## Context

Cortana — the hermes landing zone's assistant (Discord gateway, voice, MS365
mail/calendar, terminal, and native `delegate_task` subagent delegation to
Cerberus/Plutus/Tethys) — has run on **`gpt-5.4-mini`** via `openai-api`
(`config.model.default` in `landingzones/hermes/values.yaml`). That was a
volume/cost-tier pick from the 5.4 generation.

In July 2026 OpenAI superseded the 5.4/5.5 generation with the **GPT-5.6
family**, three tiers sharing a ~1M-token context window:

| Tier | API id | Positioning | Price (per 1M in/out, approx.) |
|---|---|---|---|
| Sol | `gpt-5.6-sol` | Frontier reasoning, slowest, priciest | $5 / $30 |
| Terra | `gpt-5.6-terra` | Balanced production tier | ~$2–2.50 / $12–15 |
| Luna | `gpt-5.6-luna` | Speed/volume tier | ~$0.20–1 / $1.20–6 |

(Published prices varied slightly across trackers at decision time; Plutus's
daily usage digest is the ground truth for what the switch actually costs.)

Staying on `gpt-5.4-mini` ($0.75/$4.50) meant running Cortana on a
previous-generation volume model while her job had grown past "chat": she
orchestrates delegate agents, drives tool-heavy Discord workflows, and handles
mail/calendar actions where shallow reasoning shows up as missed steps and
poor delegation decisions.

## Decision

Set Cortana's default chat model to **`gpt-5.6-terra`** (provider `openai-api`,
`base_url` unchanged). TTS (`gpt-4o-mini-tts`) and STT
(`gpt-4o-mini-transcribe`) are unaffected — they are separate `config.tts` /
`config.stt` settings and model-capability arguments don't apply to them.

## Why Terra and not Luna or Sol

- **vs Luna** (the like-for-like swap, and cheaper than today): Luna is the
  right tier for simple high-frequency calls, but Cortana's workload is the
  opposite shape — fewer, heavier turns: multi-step tool chains, delegation
  decisions (which subagent, what brief), and consequential actions (mail,
  calendar, commitments) where the cost of a wrong step exceeds the token
  savings. The capability jump is the point of the change; Luna would have
  been a generation refresh, not an upgrade.
- **vs Sol**: frontier reasoning at $5/$30 and higher latency buys little for
  an interactive assistant — Cortana's hard reasoning is delegated to
  subagents and to Claude-side fleet work anyway, and voice/Discord
  interactivity is latency-sensitive. Sol is the wrong price/latency point
  for an always-on chat orchestrator.
- **Cost is bounded and observable**: Terra is ~3–5× mini's token price, but
  Cortana's absolute OpenAI spend is small and **Plutus** reports daily
  per-provider spend to Discord, so a surprise regression is visible within a
  day. If the delta proves unjustified, the rollback is this one line back to
  Luna (not 5.4-mini — no reason to return to the old generation).

## Consequences

- One-line config change; Argo CD sync rolls the hermes Deployment via the
  config checksum annotation (~3 min lag), no image change.
- OpenAI daily spend rises (watch the Plutus digest for the real multiplier).
- Cortana's 5.6-generation context window (~1M tokens) removes the practical
  ceiling on long Discord threads/tool transcripts; no config relies on the
  old limit.
- Revisit trigger: if Plutus shows Cortana's spend dominating the OpenAI line
  without a felt quality gain, drop to `gpt-5.6-luna`; if delegation quality
  is still lacking, the next lever is prompt/toolset work, not Sol.
