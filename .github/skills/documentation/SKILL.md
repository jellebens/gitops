---
name: documentation
description: 'Create and update technical documentation with clear structure, audience targeting, and verification checks. Use for README updates, runbooks, architecture notes, onboarding docs, and release documentation.'
argument-hint: 'What documentation should be created or updated? Include audience, scope, and source files.'
user-invocable: true
---

# Documentation Workflow

## When to Use
- Writing new project documentation
- Updating docs after code or config changes
- Creating runbooks and troubleshooting guides
- Producing architecture and operations documentation
- Reviewing docs for clarity, accuracy, and completeness

## Inputs to Collect
1. Documentation target: file(s) to create or update
2. Audience: operator, developer, reviewer, or end user
3. Goal: explain concept, guide action, or record decision
4. Source of truth: code/config references to verify against
5. Constraints: tone, format, required sections, deadlines

## Procedure
1. Define the objective in one sentence.
2. Identify the primary audience and their expected skill level.
3. Gather source material from the relevant files and commands.
4. Create an outline with only required sections.
5. Draft content from high-level to detailed steps.
6. Add examples that are executable or directly verifiable.
7. Verify every factual statement against source files.
8. Remove redundant wording and ambiguous phrasing.
9. Ensure navigation quality: headings, sequence, and scanning ease.
10. Finish with validation checks and next actions.

## Decision Points
- If source files conflict:
  Use the current repository state as authoritative and call out unresolved discrepancies.
- If audience is mixed:
  Split into sections by role instead of writing one generic section.
- If scope is broad:
  Produce a concise overview document, then link follow-up docs for deep details.
- If command examples are environment-specific:
  Label prerequisites and expected environment before command blocks.

## Quality Criteria
- Accuracy: statements match current repository content.
- Actionability: procedures can be followed without hidden assumptions.
- Readability: concise language, consistent terms, and clear heading flow.
- Traceability: references to files, commands, or decisions are explicit.
- Maintainability: structure supports future incremental updates.

## Completion Checklist
1. Audience and objective are explicit in the intro.
2. Steps are ordered and reproducible.
3. Commands and paths are validated.
4. Edge cases or failure modes are documented.
5. Final section includes verification and next steps.

## Output Patterns
- README update: purpose, setup, usage, troubleshooting
- Runbook: symptoms, checks, remediation, rollback
- Architecture note: context, decision, alternatives, consequences
- Change note: what changed, why, impact, migration steps
