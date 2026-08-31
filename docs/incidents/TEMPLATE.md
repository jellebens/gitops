<!--
  Post-incident review TEMPLATE (convention est. 2026-08-31, owner-approved).

  WHEN to write one: any incident with >=30 min of degraded operation (lost
  optimization, wrong/stale data surfaced to the owner, an unwanted actuation,
  a service outage) — or anything shorter that taught a real lesson.

  HOW: copy this file to docs/incidents/YYYY-MM-DD-<short-slug>.md, fill it in,
  delete every <!-- guidance comment -->, PR into develop (docs-only — rides to
  master with the next release). Reference the Trello card(s) and every PR.

  STYLE: blameless. Name decisions and mechanisms, not people/agents-as-culprits.
  "The fix was keyed on an unverified assumption" — not "X screwed up".
  First example of the format: 2026-08-31-bluetti-staleness-deadlock.md
-->

# Post-incident review — <title> (card #NN)

**Date:** YYYY-MM-DD (→ YYYY-MM-DD if multi-day) · **Severity:** low | medium | high
<!-- low: cosmetic/observability only. medium: lost optimization, wrong data,
     bounded unwanted actuation — no safety exposure. high: safety exposure,
     data loss, or an outage of a live control path. -->
· **Status:** investigating | mitigated | resolved · **Format:** blameless SRE-style postmortem with an A3-style summary box.

---

## A3 summary (one-box view)
<!-- The lean one-pager. Someone reading ONLY this table must get the whole
     story. Keep each cell to 1-3 sentences. Fill it in LAST. -->

| | |
|---|---|
| **Background** | <!-- The relevant system behavior/design BEFORE the incident — what is supposed to happen and why. --> |
| **Problem** | <!-- The observable symptom + its impact, as the owner experienced it. --> |
| **Direct cause** | <!-- The immediate mechanism that produced the symptom (whys 1-2). --> |
| **Root cause** | <!-- The underlying reason the mechanism existed/persisted (whys 3-5). --> |
| **Countermeasures** | <!-- What was shipped, numbered; distinguish stopgap vs permanent. --> |
| **Verification** | <!-- The EVIDENCE the fix works — a live observation, not "should work". --> |
| **Follow-up** | <!-- What is intentionally left open, with owners/cards. --> |

---

## Impact
<!-- Bullet the concrete consequences: lost EUR/optimization windows, wrong
     data shown, unwanted actuations (with magnitudes), outage duration.
     ALWAYS state explicitly whether there was safety exposure or not. -->

- …
- **Safety exposure:** none | <describe>

## Timeline (YYYY-MM-DD, local)
<!-- Key beats only — detection, each diagnosis step that CHANGED the picture,
     each fix attempt (including the failed ones — failed fixes are evidence),
     mitigation, resolution, verification. Timestamped from logs where possible. -->

| Time | Event |
|---|---|
| HH:MM | … |

## Causal chain (5-whys)
<!-- Number each why; stop when the answer is a design decision or an external
     fact, not another symptom. If several causes interact, say so explicitly —
     don't force a single thread. Add an "Aggravating factor" line for anything
     that worsened or masked the incident without causing it. -->

1. **Why <symptom>?** …
2. **Why …?** …
3. …

**Aggravating factor:** …

## Resolution — what was deployed
<!-- Numbered list of the countermeasures IN THEIR DEFENSE-IN-DEPTH ORDER
     (primary mechanism first, final safety net last). For each: what it does,
     where it lives (repo/file/knob), and whether it is stopgap or permanent.
     Explicitly list anything REVERTED and why. -->

1. …

Reverted: …

## What went well / what went poorly (blameless)

**Well:** <!-- What limited the damage or sped up diagnosis — including designs
that failed safe, and owner observations that pinpointed the mechanism. -->

**Poorly — lessons:**
<!-- Each lesson gets an ID (L1, L2, …) so later docs/cards can cite it.
     Format: what happened → the transferable rule, in italics. -->
- **L1:** … *<transferable rule>*

## Action items
<!-- Checkboxes; done items stay listed (checked) so the record is complete.
     Every open item names an owner (owner/agent) or a Trello card. -->

- [x] …
- [ ] … (card #NN / owner)

## References
<!-- Every PR (repo #NN), every Trello card, runbook sections, related
     incident docs. Terse, one block. -->

<repo> PRs #… · cards #… · runbook: …
