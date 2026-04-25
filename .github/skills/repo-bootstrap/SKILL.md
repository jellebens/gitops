---
name: repo-bootstrap
description: 'Initialize or normalize this repository for AI-agent workflows by creating default dot-directories and chat customization scaffolding (.docs, .github/agents, .github/skills, hooks, scripts, AGENTS.md) and baseline ignore rules. Use when setting up a new repo or standardizing an existing one.'
argument-hint: 'Describe which defaults to create or enforce (directories, AGENTS.md, hooks, skills, .gitignore rules).'
user-invocable: true
---

# Repository Bootstrap Workflow

## See Also
- Agent customization reference: ../../../../AGENTS.md
- GitOps troubleshooting workflow: ../gitops-argocd/SKILL.md
- Documentation workflow: ../documentation/SKILL.md

## When to Use
- Creating a new repository with standard AI customization structure
- Normalizing an existing repository to the team default
- Ensuring required dot-directories and chat customization files exist
- Repairing missing or inconsistent `.gitignore` defaults for local-only paths

## Default Structure
1. `.docs/`
2. `.github/agents/`
3. `.github/skills/`
4. `.github/hooks/`
5. `.scripts/`
6. `AGENTS.md`

## Inputs to Collect
1. Which default directories to create (all by default)
2. Whether to create/update `AGENTS.md` (recommended: yes)
3. Whether to add/refresh hook config in `.github/hooks/`
4. `.gitignore` policy for local-only paths (for example `.tmp/`, `.secrets/`)
5. Whether to commit immediately after scaffolding

## Procedure
1. Inspect current structure and list missing defaults.
2. Create only missing directories and files (do not overwrite without confirmation).
3. Ensure `AGENTS.md` links to existing docs/skills rather than duplicating content.
4. Ensure `.gitignore` tracks dot-directories by default and ignores only explicit local-only paths.
5. Validate with `git status` and summarize created/updated customization files.
6. Commit with a focused message when requested.

## Guardrails
- Do not add runtime app code when running this skill.
- Do not delete existing customization files unless explicitly requested.
- Keep generated instructions concise and action-oriented.
- Prefer links to source-of-truth docs over embedded duplication.

## Completion Checklist
1. Required directories exist.
2. `AGENTS.md` exists and references repo-specific commands/conventions.
3. Hook and skill folders are present for future automation.
4. `.gitignore` contains explicit local-only ignores and avoids broad hidden-dir ignores.
5. Changes are ready to review or commit.
